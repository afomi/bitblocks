defmodule Bitblocks.Chain.BeefVerifier do
  @moduledoc """
  Checks a BEEF from anyone against the headers we hold, and says what the
  evidence shows: `POST /api/v1/beef/verify`.

  The claim is inclusion in a block, and no more. It says a transaction's bytes
  sit under a merkle root in a header. It doesn't say the transaction's scripts
  pass, that its inputs were unspent, that a token in it is real or that a
  payment happened. No script is run here.

  ## Each transaction's status

    * `proven`: its bytes hash to its txid, its BUMP climbs to a root, and that
      root is the one in a verified, canonical header at the BUMP's height.
    * `anchored`: it has no BUMP, and every input leads, within this BEEF, to
      proven transactions. It is not itself shown to be in any block.
    * `unknown`: we can't say. We hold no header at that height, or the header
      didn't pass or isn't canonical, or the BEEF doesn't carry what it needs.
    * `failed`: the evidence is wrong: the root differs from the header we hold
      at that height, the BUMP doesn't reach a root, or its shape can't be that
      block's, or an ancestor failed.

  The answer's own `status` is the subject's. A height we don't hold is always
  `unknown`.

  ## Hardening beyond the climb

    * A 64-byte transaction is refused: 64 bytes is also the preimage of an
      inner node of a merkle tree, so such a "tx" could pose as a leaf.
    * When the block's `num_tx` is known, the BUMP's tree height must be that
      block's, and the tx's offset must be inside it. That shuts out proofs of
      an inner node and of a phantom position past the last tx.

  `evaluate/3` is pure, for the headers and tip it is given.
  """

  alias Bitblocks.Chain.Beef.Reader
  alias Bitblocks.Chain.{Headers, PaymentEvidence}
  alias Bitblocks.Sync

  @maker "Distance only: the ancestry walked against our headers, with no script, amount or " <>
           "lock time checked, so validated is empty and lowestFeeRate null (BRC-237 section 2.3)."

  @claim "Inclusion in a block only. Nothing here says a transaction is valid, its scripts pass, " <>
           "its inputs were unspent, a token is genuine, or a payment was made."

  @not_checked ~w(scripts signatures input_amounts double_spends token_validity payment_terms)

  @trust "Each root is compared to the header bitblocks holds at that height: rebuilt from its " <>
           "stored fields, hashed, checked against the proof of work in its own bits, and " <>
           "built on by the next stored block. We trust our node for which chain is longest. " <>
           "Check the roots against your own headers if you can't take that on trust."

  @details %{
    root_mismatch: "The BUMP's root is not the merkle root of the block we hold at this height.",
    not_in_bump: "The txid is not a leaf at level 0 of its BUMP.",
    incomplete: "The BUMP lacks a node this txid needs to reach a root.",
    tree_height_mismatch: "The BUMP's tree height doesn't fit this block's transaction count.",
    offset_past_block: "The BUMP places this tx past the block's last transaction.",
    ambiguous_64_byte_tx:
      "A 64-byte transaction can't be told from an inner node of a merkle tree, so it is refused.",
    height_unknown: "We hold no header at this height.",
    header_unverified:
      "The header we hold at this height didn't pass its hash and proof-of-work check.",
    not_canonical: "The block we hold at this height isn't built on by the next stored block.",
    no_bump: "This transaction has no BUMP and an input that leads to no proof in this BEEF.",
    no_inputs_in_beef: "This transaction has no BUMP and its parents aren't all in this BEEF.",
    txid_only: "BEEF V2 lists this txid without its bytes, so nothing can be checked.",
    ancestor_failed: "An ancestor in this BEEF failed its check.",
    ancestor_unknown: "An ancestor in this BEEF couldn't be checked."
  }

  @doc """
  Parses and checks a BEEF. `{:ok, answer}` whatever the evidence shows, or
  `{:error, reason}` from `Beef.Reader` when the bytes aren't a BEEF. `opts`
  are `Reader.parse/2`'s limits.
  """
  @spec verify(binary(), keyword()) :: {:ok, map()} | {:error, atom()}
  def verify(bytes, opts \\ []) when is_binary(bytes) do
    with {:ok, beef} <- Reader.parse(bytes, opts) do
      tip = Sync.tip()

      headers =
        beef.bumps |> Enum.map(& &1.height) |> Kernel.++(List.wrap(tip)) |> Headers.heights()

      answer =
        beef
        |> evaluate(headers, tip)
        |> Map.put(:statement, statement(bytes, headers, tip))

      {:ok, answer}
    end
  end

  @doc """
  The BRC-237 payment evidence statement this BEEF supports
  (`Chain.PaymentEvidence.make/3`, distance only), offered beside the
  verdict: what a receiver can keep and anyone can recheck from their own
  headers. Made from the headers we hold that are both verified and
  canonical, and our tip, whose header the statement names.

    * `%{status: "made", canonical:, sha256:, ...}`: `canonical` is the
      statement's exact bytes (section 4), and `sha256` their hash, the
      value an acceptance record's `evidenceHash` takes.
    * `%{status: "refused", code:}`: BRC-237 refuses the material, with
      its code (`MALFORMED`, `ANCHOR_MISMATCH`, `CONFLICT`, `OVER_BOUND`).
    * `%{status: "unavailable", reason:}`: we hold no header at our tip that
      a statement could name.

  No conflict was looked for, so the statement says `conflicts.checked`
  false, and its event is `received`.
  """
  @spec statement(binary(), map(), integer() | nil) :: map()
  def statement(bytes, headers, tip) do
    relied_on =
      for {height, %{verified: true, canonical: true, header: hex}} <- headers, into: %{} do
        {height, Base.decode16!(hex, case: :lower)}
      end

    source = %{tip: tip, headers: relied_on}

    if is_integer(tip) and Map.has_key?(source.headers, tip) do
      case PaymentEvidence.make({:beef, bytes}, source) do
        {:ok, canonical} ->
          %{
            status: "made",
            version: "bsv-payment-evidence/v1",
            canonical: canonical,
            sha256: :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower),
            maker: @maker
          }

        {:error, code} ->
          %{status: "refused", code: code, maker: @maker}
      end
    else
      %{
        status: "unavailable",
        reason: "We hold no verified header at our tip, so no statement can name one.",
        maker: @maker
      }
    end
  end

  @doc """
  The answer for a parsed BEEF, given `%{height => header}` (`Chain.Headers`)
  and the height of our tip.
  """
  @spec evaluate(map(), map(), integer() | nil) :: map()
  def evaluate(%{subject: subject} = beef, headers, tip) do
    indexes = bump_indexes(beef)

    proofs =
      for %{bump_index: index} = tx when is_integer(index) <- beef.transactions, into: %{} do
        bump = Enum.at(beef.bumps, index)
        {tx.txid, prove(tx, bump, Map.fetch!(indexes, index), Map.get(headers, bump.height), tip)}
      end

    results =
      Enum.reduce(beef.transactions, proofs, fn tx, results ->
        Map.put_new_lazy(results, tx.txid, fn -> without_bump(tx, results) end)
      end)

    entries = Enum.map(beef.transactions, &entry(&1, Map.fetch!(results, &1.txid)))
    answer = Map.fetch!(results, subject)

    %{
      format: format(beef),
      subject_txid: subject,
      status: answer.status,
      reason: Map.get(answer, :reason),
      detail: detail(answer),
      in_block: answer.status == :proven,
      block_height: Map.get(answer, :block_height),
      block_hash: Map.get(answer, :block_hash),
      merkleroot: if(answer.status == :proven, do: answer.merkleroot),
      confirmations: Map.get(answer, :confirmations),
      proven: for(%{status: :proven, txid: txid} <- entries, do: txid),
      transactions: entries,
      unused_bumps: unused_bumps(beef),
      indexed_tip_height: tip,
      claim: @claim,
      not_checked: @not_checked,
      trust: @trust
    }
  end

  defp format(%{format: format, atomic: true}), do: "atomic_beef_#{format}"
  defp format(%{format: format}), do: "beef_#{format}"

  defp bump_indexes(%{bumps: bumps, transactions: txs}) do
    for index <- txs |> Enum.map(& &1.bump_index) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
        into: %{} do
      {index, bumps |> Enum.at(index) |> Reader.index()}
    end
  end

  defp unused_bumps(%{bumps: bumps, transactions: txs}) do
    used = MapSet.new(txs, & &1.bump_index)
    for index <- 0..(length(bumps) - 1)//1, not MapSet.member?(used, index), do: index
  end

  # --- a tx with a BUMP ---------------------------------------------------------

  defp prove(%{raw: raw}, _bump, _index, _header, _tip) when byte_size(raw) == 64,
    do: outcome(:failed, :ambiguous_64_byte_tx)

  defp prove(tx, bump, index, header, tip) do
    case Reader.root(index, tx.txid) do
      {:ok, root, offset} ->
        against_header(root, offset, bump, header, tip)

      {:error, reason} ->
        outcome(:failed, reason)
    end
  end

  defp against_header(root, offset, bump, header, tip) do
    climbed = %{block_height: bump.height, merkleroot: root, index: offset}

    case header_status(root, offset, bump, header) do
      :proven ->
        Map.merge(climbed, %{
          status: :proven,
          block_hash: header.hash,
          confirmations: (tip || bump.height) - bump.height + 1
        })

      {status, reason} ->
        Map.merge(climbed, outcome(status, reason))
    end
  end

  defp header_status(_root, _offset, _bump, nil), do: {:unknown, :height_unknown}

  defp header_status(_root, _offset, _bump, %{verified: false}),
    do: {:unknown, :header_unverified}

  defp header_status(_root, _offset, _bump, %{canonical: false}), do: {:unknown, :not_canonical}

  defp header_status(root, offset, bump, %{merkleroot: merkleroot, num_tx: num_tx}) do
    cond do
      root != String.downcase(merkleroot) -> {:failed, :root_mismatch}
      not is_integer(num_tx) or num_tx <= 0 -> :proven
      length(bump.path) != tree_height(num_tx) -> {:failed, :tree_height_mismatch}
      offset >= num_tx -> {:failed, :offset_past_block}
      true -> :proven
    end
  end

  # A one-transaction block is one level in BRC-74: the txid and nothing above.
  defp tree_height(1), do: 1
  defp tree_height(num_tx), do: bit_length(num_tx - 1)

  defp bit_length(0), do: 0
  defp bit_length(n), do: 1 + bit_length(Bitwise.bsr(n, 1))

  # --- a tx without one ---------------------------------------------------------

  # Parents come first in the file (Reader), so theirs are already in `results`.
  defp without_bump(%{txid_only: true}, _results), do: outcome(:unknown, :txid_only)
  defp without_bump(%{coinbase: true}, _results), do: outcome(:unknown, :no_bump)

  defp without_bump(tx, results) do
    statuses = Enum.map(tx.parents, &(results |> Map.get(&1, %{}) |> Map.get(:status)))

    cond do
      :failed in statuses -> outcome(:failed, :ancestor_failed)
      nil in statuses -> outcome(:unknown, :no_inputs_in_beef)
      :unknown in statuses -> outcome(:unknown, :ancestor_unknown)
      true -> %{status: :anchored}
    end
  end

  # --- the answer ---------------------------------------------------------------

  defp outcome(status, reason), do: %{status: status, reason: reason}

  defp entry(tx, result) do
    result
    |> Map.merge(%{txid: tx.txid, bump_index: tx.bump_index, detail: detail(result)})
    |> Map.put_new(:reason, nil)
  end

  defp detail(%{reason: reason}), do: Map.fetch!(@details, reason)
  defp detail(_result), do: nil
end
