defmodule Bitblocks.Bap do
  @moduledoc """
  BAP identities (#32): who an identity is, read from the chain and not from a
  wallet. A read-only index; the rules are written down in docs/BAP.md.

      OP_FALSE OP_RETURN 1BAPSuaPnfGnSBM3GLV9yhxUdYe4vGbdMT
        ID <bap_id> <declared address>      | AIP…
        ALIAS <bap_id> <profile JSON>       | AIP…
        ATTEST <attestation hash> <seq>     | AIP…
        REVOKE <attestation hash> <seq>     | AIP…

  Indexing and reading are apart. `index/1` (the `index_bap` pipeline step)
  stores what each output says, once its AIP signature checks. `identity/1`
  folds an identity's records through the rules when asked, so a change of rule
  needs no re-index, and a reorg that moves a transaction moves its records:
  height and block are read from the `transactions` row.

  The step must never fail on what a transaction contains: a failing tx step
  rolls the block back, and anyone can write any bytes. Anything unexpected
  is no record, and every stored string is checked for its shape first.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Bap.Record
  alias Bitblocks.Chain.{RawTx, Transaction}
  alias Bitblocks.{Aip, Repo, SyncProgress}

  @prefix "1BAPSuaPnfGnSBM3GLV9yhxUdYe4vGbdMT"
  @separator "|"

  # A BAP ID is base58 of 20 bytes, an address base58check of 25.
  @base58 "[1-9A-HJ-NP-Za-km-z]"

  # A profile is a small JSON object; the image is a 1sat:// outpoint.
  @max_profile_bytes 64_000

  # Bounds on what one identity's read may load.
  @max_id_records 1_000
  @max_aliases 100
  @max_attestations 500
  @max_candidates 5

  @doc "The BAP protocol prefix."
  def prefix, do: @prefix

  @doc "The BAP ID of a root address: `base58(ripemd160(sha256(address)))`."
  @spec bap_id_of(String.t()) :: String.t()
  def bap_id_of(address) when is_binary(address) do
    hash = :crypto.hash(:ripemd160, :crypto.hash(:sha256, address))
    B58.encode58(hash)
  end

  # -- Indexing ------------------------------------------------------------------

  @doc """
  Stores the BAP records in `tx`. A no-op unless a valid AIP signature was
  found on it (`aip_signers`), so other txs cost nothing. Idempotent on `{txid,
  vout}`. Returns the number of records newly stored.
  """
  @spec index(Transaction.t()) :: non_neg_integer()
  def index(%Transaction{aip_signers: [_ | _], raw: raw, txid: txid}) when is_binary(raw) do
    write(records(txid, raw))
  end

  def index(_tx), do: 0

  @doc """
  The records in a raw hex tx with valid AIP signatures, as rows. Total: what
  can't be read as a BAP record is simply not one.
  """
  @spec records(String.t(), String.t()) :: [map()]
  def records(txid, raw) do
    case RawTx.parse(raw) do
      {:ok, %BSV.Tx{outputs: outputs}} ->
        outputs
        |> Enum.with_index()
        |> Enum.flat_map(fn {output, vout} -> output_record(output, txid, vout) end)

      _ ->
        []
    end
  rescue
    e ->
      Logger.warning("Bap: skipped #{txid}: #{inspect(e.__struct__)}")
      []
  end

  defp output_record(%BSV.TxOut{script: %BSV.Script{chunks: chunks}}, txid, vout) do
    with {:ok, position, action, fields} <- fields(chunks),
         {:ok, signer} <- signer(chunks, position, length(fields)),
         {:ok, attrs} <- attrs(action, fields) do
      [Map.merge(attrs, %{txid: txid, vout: vout, action: action, signer: signer})]
    else
      _ -> []
    end
  end

  defp output_record(_output, _txid, _vout), do: []

  # The BAP section of an OP_RETURN output: where its prefix sits in the data
  # (AIP counts from there), its action and the fields up to the next `|`.
  defp fields(chunks) do
    data = chunks |> Enum.drop_while(&(&1 != :OP_RETURN)) |> Enum.drop(1)

    with position when is_integer(position) <- Enum.find_index(data, &(&1 == @prefix)),
         true <- position == 0 or Enum.at(data, position - 1) == @separator,
         [action | rest] when is_binary(action) <- Enum.drop(data, position + 1) do
      {:ok, position, action, Enum.take_while(rest, &(&1 != @separator))}
    else
      _ -> :error
    end
  end

  # The first valid signature that covers every field of this section. AIP
  # numbers fields from 0 (`OP_RETURN`), so data position p is field p + 1. An
  # AIP that names field indexes may have left these fields out of what it signed.
  defp signer(chunks, position, field_count) do
    section = (position + 1)..(position + 2 + field_count)

    chunks
    |> Aip.signatures()
    |> Enum.find_value(:error, fn
      %{valid: true, address: address, field_indexes: indexes} when is_binary(address) ->
        if is_nil(indexes) or Enum.all?(section, &(&1 in indexes)), do: {:ok, address}

      _ ->
        nil
    end)
  end

  defp attrs("ID", [bap_id, address]) do
    if bap_id?(bap_id) and address?(address),
      do: {:ok, %{bap_id: bap_id, address: address}},
      else: :error
  end

  defp attrs("ALIAS", [bap_id, json]) do
    if bap_id?(bap_id), do: {:ok, %{bap_id: bap_id, profile: profile(json)}}, else: :error
  end

  defp attrs(action, [hash, seq]) when action in ["ATTEST", "REVOKE"] do
    if hash?(hash) and seq?(seq),
      do: {:ok, %{attestation_hash: hash, seq: seq}},
      else: :error
  end

  defp attrs(_action, _fields), do: :error

  defp bap_id?(value), do: is_binary(value) and value =~ ~r/\A#{@base58}{20,44}\z/
  defp address?(value), do: is_binary(value) and value =~ ~r/\A#{@base58}{25,35}\z/
  defp hash?(value), do: is_binary(value) and value =~ ~r/\A[0-9a-zA-Z]{32,128}\z/
  defp seq?(value), do: is_binary(value) and value =~ ~r/\A[0-9]{1,20}\z/

  # A JSON object Postgres can hold: jsonb refuses \u0000, and a refused insert
  # would fail the block. Anything else is an ALIAS with no profile.
  defp profile(json) when is_binary(json) and byte_size(json) <= @max_profile_bytes do
    with true <- String.valid?(json),
         false <- String.contains?(json, ["\\u0000", <<0>>]),
         {:ok, %{} = profile} <- Jason.decode(json) do
      profile
    else
      _ -> nil
    end
  end

  defp profile(_json), do: nil

  defp write([]), do: 0

  defp write(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    version = Bitblocks.Chain.TxPipeline.Steps.IndexBap.version()

    defaults = %{
      bap_id: nil,
      address: nil,
      attestation_hash: nil,
      seq: nil,
      profile: nil,
      version: version,
      inserted_at: now,
      updated_at: now
    }

    {count, _} =
      Repo.insert_all(Record, Enum.map(rows, &Map.merge(defaults, &1)),
        on_conflict: :nothing,
        conflict_target: [:txid, :vout]
      )

    count
  end

  @doc """
  Imports txs named by a hint (a txid from any source: only a candidate), and
  indexes them. For a record in a block the sync hasn't reached. Bytes are
  checked against the txid, as for collections. Returns `%{txid => records}`.
  """
  @spec import_txs([String.t()]) :: %{String.t() => non_neg_integer()}
  def import_txs(txids) do
    Bitblocks.OrdinalCollections.import_txs(txids)

    from(t in Transaction, where: t.txid in ^txids)
    |> Repo.all()
    |> Map.new(fn tx ->
      index(tx)
      {tx.txid, Repo.aggregate(from(r in Record, where: r.txid == ^tx.txid), :count)}
    end)
  end

  # -- Reading -------------------------------------------------------------------

  @doc """
  An identity, or nil when no ID record for it is accepted. See docs/BAP.md for
  the rules. Returns `%{bap_id, root_address, current_address, first_record,
  rotations, current_profile, rejected, keys, as_of}`.
  """
  @spec identity(String.t()) :: map() | nil
  def identity(bap_id) when is_binary(bap_id) do
    chain =
      bap_id
      |> id_records()
      |> Enum.reduce(new_chain(bap_id), &follow_id/2)

    case chain.accepted do
      [] -> nil
      accepted -> describe(chain, Enum.reverse(accepted))
    end
  end

  defp new_chain(bap_id),
    do: %{bap_id: bap_id, root: nil, current: nil, accepted: [], rejected: [], keys: []}

  # The first record must be signed by the root: the one key whose address
  # hashes to the BAP ID. A later one by the root, or by the address the chain
  # declares at that moment. So a stranger can't claim an ID, and a key rotated
  # away can no longer speak for it.
  defp follow_id(record, %{root: nil, bap_id: bap_id} = chain) do
    if bap_id_of(record.signer) == bap_id do
      %{
        chain
        | root: record.signer,
          current: record.address,
          accepted: [record],
          keys: [%{address: record.address, from: order(record), until: nil}]
      }
    else
      reject(chain, record, "not signed by the root key")
    end
  end

  defp follow_id(record, chain) do
    if record.signer in [chain.root, chain.current] do
      %{
        chain
        | current: record.address,
          accepted: [record | chain.accepted],
          keys: [
            %{address: record.address, from: order(record), until: nil}
            | close_key(chain.keys, order(record))
          ]
      }
    else
      reject(chain, record, "not signed by the root or the current key")
    end
  end

  defp close_key([current | older], until), do: [%{current | until: until} | older]

  defp reject(chain, record, reason),
    do: %{
      chain
      | rejected: [%{txid: record.txid, vout: record.vout, reason: reason} | chain.rejected]
    }

  defp describe(chain, [first | rotations]) do
    {profile, alias_rejections} = current_profile(chain)
    overview = SyncProgress.snapshot().overview

    %{
      bap_id: chain.bap_id,
      root_address: chain.root,
      current_address: chain.current,
      first_record: place(first),
      rotations: Enum.map(rotations, &rotation(&1, chain.root)),
      current_profile: profile,
      rejected: Enum.reverse(chain.rejected) ++ alias_rejections,
      keys: chain.keys,
      as_of: %{
        complete_through: overview[:complete_through],
        tip: overview[:our_tip],
        first_record_final:
          is_integer(overview[:complete_through]) and
            first.block_height <= overview[:complete_through]
      }
    }
  end

  defp place(record) do
    Map.take(record, [:txid, :vout, :block_height, :block_hash, :block_offset, :address, :signer])
  end

  defp rotation(record, root) do
    record
    |> place()
    |> Map.put(:signed_by, if(record.signer == root, do: "root", else: "previous"))
  end

  # The newest ALIAS signed by a key the identity held at that moment, with a
  # profile. Newest is chain order, never a date in the record: that is claimed.
  defp current_profile(chain) do
    {accepted, rejected} =
      chain.bap_id
      |> alias_records()
      |> Enum.split_with(&held?(chain, &1))

    case Enum.find(accepted, & &1.profile) do
      nil ->
        {nil, Enum.map(rejected, &rejection(&1, "not signed by a key held at that moment"))}

      record ->
        {record |> place() |> Map.delete(:address) |> Map.put(:profile, record.profile),
         Enum.map(rejected, &rejection(&1, "not signed by a key held at that moment"))}
    end
  end

  defp rejection(record, reason), do: %{txid: record.txid, vout: record.vout, reason: reason}

  defp held?(chain, record) do
    at = order(record)
    first = chain.keys |> List.last() |> Map.fetch!(:from)

    at >= first and
      (record.signer == chain.root or
         Enum.any?(
           chain.keys,
           &(&1.address == record.signer and &1.from <= at and (&1.until == nil or at < &1.until))
         ))
  end

  defp id_records(bap_id) do
    from(r in Record, where: r.bap_id == ^bap_id and r.action == "ID")
    |> canonical(:asc, @max_id_records)
    |> Enum.sort_by(&order/1)
  end

  defp alias_records(bap_id) do
    from(r in Record, where: r.bap_id == ^bap_id and r.action == "ALIAS")
    |> canonical(:desc, @max_aliases)
    |> Enum.sort_by(&order/1, :desc)
  end

  # Records whose tx sits on the stored chain, with its height and block.
  defp canonical(query, direction, limit) do
    from([r] in query,
      join: t in Transaction,
      on: t.txid == r.txid,
      where: not is_nil(t.block_height),
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM blocks b WHERE b.height = ? AND b.hash IS DISTINCT FROM ?)",
          t.block_height,
          t.block_hash
        ),
      order_by: [{^direction, t.block_height}, {^direction, r.id}],
      limit: ^limit,
      select: %{
        txid: r.txid,
        vout: r.vout,
        action: r.action,
        address: r.address,
        signer: r.signer,
        attestation_hash: r.attestation_hash,
        seq: r.seq,
        profile: r.profile,
        block_height: t.block_height,
        block_hash: t.block_hash,
        block_offset: t.raw_offset
      }
    )
    |> Repo.all()
  end

  # Chain order: height, place in the block where known, then txid. Within a
  # tx an ID comes before anything it enables: a wallet's first publish puts
  # the ID and the ALIAS it authorises side by side. nil sorts after integers.
  defp order(record) do
    {record.block_height, record.block_offset, record.txid, action_rank(record.action),
     record.vout}
  end

  defp action_rank("ID"), do: 0
  defp action_rank(_), do: 1

  @doc """
  What an identity attested, newest first, each with whether it was revoked by
  a key the identity held. nil when there is no such identity. What others
  attested about it can't be listed: an attestation names only the hash of a
  claim, and only its holder knows the claim.
  """
  @spec attestations(String.t()) :: %{made: [map()]} | nil
  def attestations(bap_id) do
    with %{} = identity <- identity(bap_id) do
      chain = %{root: identity.root_address, keys: identity.keys}
      signers = [chain.root | Enum.map(chain.keys, & &1.address)]

      records =
        from(r in Record,
          where: r.signer in ^signers and r.action in ["ATTEST", "REVOKE"]
        )
        |> canonical(:desc, @max_attestations)
        |> Enum.filter(&held?(chain, &1))

      revoked = for %{action: "REVOKE"} = r <- records, into: MapSet.new(), do: r.attestation_hash

      made =
        for %{action: "ATTEST"} = r <- Enum.sort_by(records, &order/1, :desc) do
          r
          |> Map.take([:txid, :vout, :block_height, :attestation_hash, :seq, :signer])
          |> Map.put(:revoked, MapSet.member?(revoked, r.attestation_hash))
        end

      %{made: made}
    end
  end

  @doc """
  The identities an address has signed for, whether it is their current key.
  `[%{bap_id, current}]`; a record that names the address but isn't accepted
  counts for nothing.
  """
  @spec by_address(String.t()) :: [%{bap_id: String.t(), current: boolean()}]
  def by_address(address) do
    from(r in Record,
      where: r.action == "ID" and (r.address == ^address or r.signer == ^address),
      distinct: true,
      limit: @max_candidates,
      select: r.bap_id
    )
    |> Repo.all()
    |> Enum.flat_map(fn bap_id ->
      case identity(bap_id) do
        nil ->
          []

        identity ->
          keys = [identity.root_address | Enum.map(identity.keys, & &1.address)]

          if address in keys,
            do: [%{bap_id: bap_id, current: identity.current_address == address}],
            else: []
      end
    end)
  end
end
