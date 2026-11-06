defmodule Bitblocks.Chain.Beef.Reader do
  @moduledoc """
  A strict reader for BEEF from anyone: BEEF V1 (BRC-62), BEEF V2 (BRC-96),
  Atomic BEEF (BRC-95) around either, and BUMP (BRC-74).

  It takes untrusted bytes and has no database, no node and no dependency
  beyond `:crypto`, so it can move to bsv-ex as it stands. It answers what the
  bytes say and how they fit together. Whether a root belongs to a real block
  is the caller's question (`Bitblocks.Chain.BeefVerifier`).

  Every failure is `{:error, reason}`, with `reason` one of a fixed set of
  atoms. Nothing raises, and nothing becomes an atom from the input.

  ## What is refused

    * anything larger than the limits (`:max_bytes`, `:max_bumps`,
      `:max_transactions`, `:max_leaves`, each an option of `parse/2`);
    * truncation, and any byte after the end;
    * a VarInt that isn't in its shortest form, as a node refuses one;
    * a BUMP with no levels, more than 64, a block height past `2^32 - 1`, no
      leaves at level 0, an offset that doesn't fit its level, two leaves at
      one offset, a flag outside BRC-74, or a duplicate leaf at an even offset
      (a duplicate stands for the right-hand node of a last pair);
    * a tx with no inputs or no outputs, which also refuses Extended Format;
    * a has-BUMP flag other than 0 or 1, or a BUMP index past the list;
    * the same txid twice;
    * a tx with no BUMP placed ahead of a parent in the same BEEF (BRC-62);
    * in Atomic BEEF, a subject that isn't present or a tx outside its ancestry
      (BRC-95). Ancestry stops at a tx with a BUMP, so that tx's own parents are
      outside it, as the spec says and the reference SDK enforces.

  ## Shapes

  `parse/2` gives `%{format:, atomic:, subject:, bumps:, transactions:}`:

    * `format` is `:v1` or `:v2`, and `atomic` a boolean;
    * `subject` is the display-hex txid the BEEF is about: the one Atomic BEEF
      names, or else the last tx;
    * a BUMP is `%{height:, path: [[leaf]]}`, `path` indexed by tree level, and
      a leaf is `%{offset:, hash: <<32 bytes>> | nil, txid:, duplicate:}` with
      `hash` in internal byte order;
    * a tx is `%{txid:, raw:, bump_index:, parents:, coinbase:, txid_only:}`,
      `txid` and `parents` as display hex. A BEEF V2 txid-only entry has
      `raw: nil`: it carries nothing to hash.

  Atomic BEEF's subject is stored in internal byte order, as the reference SDK
  reads and writes it. BRC-95 doesn't say which.

  ## Roots

  `index/1` computes each node a BUMP implies once, so its cost is linear in
  the BUMP however many txs climb it, and `root/2` is then a walk up the tree.
  A BUMP may leave out a node its leaves below can compute, which is how one
  BUMP serves several txs.
  """

  import Bitwise

  @version_v1 <<0x01, 0x00, 0xBE, 0xEF>>
  @version_v2 <<0x02, 0x00, 0xBE, 0xEF>>
  @atomic_prefix <<0x01, 0x01, 0x01, 0x01>>

  @flag_data 0
  @flag_duplicate 1
  @flag_txid 2

  @tx_raw 0
  @tx_raw_and_bump 1
  @tx_txid_only 2

  @max_tree_height 64
  @max_block_height 0xFFFFFFFF
  @coinbase_vout 0xFFFFFFFF

  @limits %{
    max_bytes: 16_000_000,
    max_bumps: 1_024,
    max_transactions: 16_384,
    max_leaves: 262_144
  }

  @type reason ::
          :too_large
          | :too_many_bumps
          | :too_many_transactions
          | :too_many_leaves
          | :truncated
          | :trailing_bytes
          | :unknown_format
          | :varint_not_minimal
          | :block_height_out_of_range
          | :tree_height_out_of_range
          | :empty_level
          | :offset_out_of_range
          | :duplicate_offset
          | :bad_leaf_flag
          | :bad_duplicate_offset
          | :bad_transaction
          | :bad_transaction_flag
          | :bump_index_out_of_range
          | :no_transactions
          | :duplicate_transaction
          | :transactions_out_of_order
          | :atomic_subject_missing
          | :atomic_unrelated_transaction

  @doc "The limits `parse/2` applies unless given others."
  @spec limits() :: map()
  def limits, do: @limits

  @doc """
  Reads a BEEF, V1 or V2, bare or Atomic.

  Options override `limits/0`: `:max_bytes`, `:max_bumps`, `:max_transactions`,
  `:max_leaves`.
  """
  @spec parse(binary(), keyword()) :: {:ok, map()} | {:error, reason()}
  def parse(bytes, opts \\ []) when is_binary(bytes) do
    limits = Map.merge(@limits, Map.new(opts))

    with :ok <- within(byte_size(bytes), limits.max_bytes, :too_large),
         {:ok, atomic_subject, body} <- read_envelope(bytes),
         {:ok, format, rest} <- read_version(body),
         {:ok, bump_count, rest} <- read_varint(rest),
         :ok <- within(bump_count, limits.max_bumps, :too_many_bumps),
         {:ok, bumps, rest} <- read_many(bump_count, rest, &parse_bump/1),
         :ok <- within(leaf_count(bumps), limits.max_leaves, :too_many_leaves),
         {:ok, tx_count, rest} <- read_varint(rest),
         :ok <- within(tx_count, limits.max_transactions, :too_many_transactions),
         {:ok, txs, rest} <- read_many(tx_count, rest, tx_reader(format)),
         :ok <- at_end(rest),
         :ok <- check_transactions(txs, length(bumps)),
         :ok <- check_atomic(atomic_subject, txs) do
      {:ok,
       %{
         format: format,
         atomic: atomic_subject != nil,
         subject: atomic_subject || List.last(txs).txid,
         bumps: bumps,
         transactions: txs
       }}
    end
  end

  @doc "Reads one BUMP from the head of a binary: `{:ok, bump, rest}`."
  @spec parse_bump(binary()) :: {:ok, map(), binary()} | {:error, reason()}
  def parse_bump(binary) when is_binary(binary) do
    with {:ok, height, rest} <- read_varint(binary),
         :ok <- within(height, @max_block_height, :block_height_out_of_range),
         {:ok, tree_height, rest} <- read_tree_height(rest),
         {:ok, path, rest} <- read_levels(0, tree_height, rest, []) do
      {:ok, %{height: height, path: path}, rest}
    end
  end

  @doc "The txid (display hex) of a raw tx."
  @spec txid(binary()) :: String.t()
  def txid(raw) when is_binary(raw), do: raw |> sha256d() |> display()

  # --- envelope ----------------------------------------------------------------

  defp read_envelope(<<@atomic_prefix, subject::binary-size(32), body::binary>>),
    do: {:ok, display(subject), body}

  defp read_envelope(<<@atomic_prefix, _::binary>>), do: {:error, :truncated}
  defp read_envelope(body), do: {:ok, nil, body}

  defp read_version(<<@version_v1, rest::binary>>), do: {:ok, :v1, rest}
  defp read_version(<<@version_v2, rest::binary>>), do: {:ok, :v2, rest}
  defp read_version(bytes) when byte_size(bytes) < 4, do: {:error, :truncated}
  defp read_version(_), do: {:error, :unknown_format}

  defp at_end(<<>>), do: :ok
  defp at_end(_), do: {:error, :trailing_bytes}

  defp within(value, limit, _reason) when value <= limit, do: :ok
  defp within(_value, _limit, reason), do: {:error, reason}

  defp leaf_count(bumps) do
    for %{path: path} <- bumps, leaves <- path, reduce: 0 do
      total -> total + length(leaves)
    end
  end

  # --- BUMP --------------------------------------------------------------------

  defp read_tree_height(<<height, rest::binary>>) when height in 1..@max_tree_height,
    do: {:ok, height, rest}

  defp read_tree_height(<<>>), do: {:error, :truncated}
  defp read_tree_height(_), do: {:error, :tree_height_out_of_range}

  defp read_levels(height, height, rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp read_levels(level, height, rest, acc) do
    with {:ok, count, rest} <- read_varint(rest),
         :ok <- level_has_leaves(level, count),
         {:ok, leaves, rest} <- read_many(count, rest, &read_leaf/1),
         :ok <- check_level(leaves, height - level) do
      read_levels(level + 1, height, rest, [leaves | acc])
    end
  end

  # A level above 0 may be empty: a BUMP that merges proofs leaves out what the
  # leaves below compute.
  defp level_has_leaves(0, 0), do: {:error, :empty_level}
  defp level_has_leaves(_level, _count), do: :ok

  defp check_level(leaves, levels_above) do
    bound = 1 <<< levels_above
    offsets = Enum.map(leaves, & &1.offset)

    cond do
      Enum.any?(offsets, &(&1 >= bound)) ->
        {:error, :offset_out_of_range}

      length(Enum.uniq(offsets)) != length(offsets) ->
        {:error, :duplicate_offset}

      Enum.any?(leaves, &(&1.duplicate and band(&1.offset, 1) == 0)) ->
        {:error, :bad_duplicate_offset}

      true ->
        :ok
    end
  end

  defp read_leaf(binary) do
    with {:ok, offset, rest} <- read_varint(binary), do: read_flagged_leaf(offset, rest)
  end

  defp read_flagged_leaf(offset, <<@flag_duplicate, rest::binary>>),
    do: {:ok, %{offset: offset, hash: nil, txid: false, duplicate: true}, rest}

  defp read_flagged_leaf(offset, <<@flag_data, hash::binary-size(32), rest::binary>>),
    do: {:ok, %{offset: offset, hash: hash, txid: false, duplicate: false}, rest}

  defp read_flagged_leaf(offset, <<@flag_txid, hash::binary-size(32), rest::binary>>),
    do: {:ok, %{offset: offset, hash: hash, txid: true, duplicate: false}, rest}

  defp read_flagged_leaf(_offset, <<flag, _::binary>>) when flag in [@flag_data, @flag_txid],
    do: {:error, :truncated}

  defp read_flagged_leaf(_offset, <<>>), do: {:error, :truncated}
  defp read_flagged_leaf(_offset, _), do: {:error, :bad_leaf_flag}

  # --- roots -------------------------------------------------------------------

  @doc """
  A BUMP's nodes, computed once, for `root/2`: every node it states and every
  node its leaves below imply, keyed `{level, offset}`, and the offset of each
  hash at level 0.
  """
  @spec index(map()) :: map()
  def index(%{path: path}) do
    {nodes, _implied} =
      path
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}}, fn {leaves, level}, {nodes, implied} ->
        stated = Map.new(leaves, &{&1.offset, if(&1.duplicate, do: :duplicate, else: &1.hash)})
        at_level = Map.merge(implied, stated)
        stored = Map.new(at_level, fn {offset, node} -> {{level, offset}, node} end)
        {Map.merge(nodes, stored), parents(at_level)}
      end)

    level_zero = List.first(path, [])

    %{
      nodes: nodes,
      levels: length(path),
      only_leaf?: length(path) == 1 and length(level_zero) == 1,
      offsets:
        level_zero
        |> Enum.reject(& &1.duplicate)
        |> Enum.sort_by(& &1.offset, :desc)
        |> Map.new(&{&1.hash, &1.offset})
    }
  end

  defp parents(at_level) do
    for {offset, left} <- at_level,
        band(offset, 1) == 0,
        is_binary(left),
        right = Map.get(at_level, offset + 1),
        into: %{} do
      {offset >>> 1, sha256d(left <> if(right == :duplicate, do: left, else: right))}
    end
  end

  @doc """
  Climbs from `txid` (display hex) to the root (display hex), and gives the
  offset the BUMP places it at: `{:ok, root, offset}`.

  Takes a BUMP or its `index/1`. `{:error, :not_in_bump}` when the txid isn't a
  leaf at level 0, and `{:error, :incomplete}` when a node it needs is missing.
  """
  @spec root(map(), String.t()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, :not_in_bump | :incomplete}
  def root(%{path: _} = bump, txid), do: bump |> index() |> root(txid)

  def root(%{offsets: offsets} = index, txid) do
    hash = internal(txid)

    case offsets do
      %{^hash => offset} ->
        with {:ok, top} <- climb(index, 0, offset, hash), do: {:ok, display(top), offset}

      _ ->
        {:error, :not_in_bump}
    end
  end

  # One transaction in the block: it is the root.
  defp climb(%{only_leaf?: true}, 0, _offset, hash), do: {:ok, hash}
  defp climb(%{levels: levels}, levels, _offset, hash), do: {:ok, hash}

  defp climb(%{nodes: nodes} = index, level, offset, hash) do
    pair =
      case {Map.get(nodes, {level, bxor(offset, 1)}), band(offset, 1)} do
        {nil, _} -> nil
        {:duplicate, _} -> hash <> hash
        {sibling, 0} -> hash <> sibling
        {sibling, 1} -> sibling <> hash
      end

    if pair,
      do: climb(index, level + 1, offset >>> 1, sha256d(pair)),
      else: {:error, :incomplete}
  end

  # --- transactions ------------------------------------------------------------

  defp tx_reader(:v1), do: &read_v1_entry/1
  defp tx_reader(:v2), do: &read_v2_entry/1

  defp read_v1_entry(binary) do
    with {:ok, tx, rest} <- read_tx(binary) do
      case rest do
        <<0, rest::binary>> -> {:ok, tx, rest}
        <<1, rest::binary>> -> read_bump_index(tx, rest)
        <<>> -> {:error, :truncated}
        _ -> {:error, :bad_transaction_flag}
      end
    end
  end

  defp read_v2_entry(<<@tx_raw, rest::binary>>), do: read_tx(rest)

  defp read_v2_entry(<<@tx_raw_and_bump, rest::binary>>) do
    with {:ok, index, rest} <- read_varint(rest),
         {:ok, tx, rest} <- read_tx(rest) do
      {:ok, %{tx | bump_index: index}, rest}
    end
  end

  defp read_v2_entry(<<@tx_txid_only, hash::binary-size(32), rest::binary>>) do
    {:ok,
     %{
       txid: display(hash),
       raw: nil,
       bump_index: nil,
       parents: [],
       coinbase: false,
       txid_only: true
     }, rest}
  end

  defp read_v2_entry(<<tag, _::binary>>) when tag == @tx_txid_only, do: {:error, :truncated}
  defp read_v2_entry(<<>>), do: {:error, :truncated}
  defp read_v2_entry(_), do: {:error, :bad_transaction_flag}

  defp read_bump_index(tx, rest) do
    with {:ok, index, rest} <- read_varint(rest), do: {:ok, %{tx | bump_index: index}, rest}
  end

  defp read_tx(<<_version::binary-size(4), rest::binary>> = binary) do
    with {:ok, input_count, rest} <- read_varint(rest),
         :ok <- some(input_count),
         {:ok, inputs, rest} <- read_many(input_count, rest, &read_input/1),
         {:ok, output_count, rest} <- read_varint(rest),
         :ok <- some(output_count),
         {:ok, _outputs, rest} <- read_many(output_count, rest, &read_output/1),
         <<_lock_time::binary-size(4), rest::binary>> <- rest do
      raw = binary_part(binary, 0, byte_size(binary) - byte_size(rest))
      {spent, coinbase} = Enum.split_with(inputs, &(&1 != :coinbase))

      {:ok,
       %{
         txid: txid(raw),
         raw: raw,
         bump_index: nil,
         parents: Enum.uniq(spent),
         coinbase: coinbase != [],
         txid_only: false
       }, rest}
    else
      {:error, _} = error -> error
      _ -> {:error, :truncated}
    end
  end

  defp read_tx(_), do: {:error, :truncated}

  defp some(0), do: {:error, :bad_transaction}
  defp some(_), do: :ok

  defp read_input(<<prev::binary-size(32), vout::little-32, rest::binary>>) do
    with {:ok, _script, rest} <- read_script(rest),
         <<_sequence::binary-size(4), rest::binary>> <- rest do
      {:ok, if(coinbase?(prev, vout), do: :coinbase, else: display(prev)), rest}
    else
      {:error, _} = error -> error
      _ -> {:error, :truncated}
    end
  end

  defp read_input(_), do: {:error, :truncated}

  defp coinbase?(<<0::256>>, @coinbase_vout), do: true
  defp coinbase?(_prev, _vout), do: false

  defp read_output(<<_satoshis::binary-size(8), rest::binary>>), do: read_script(rest)
  defp read_output(_), do: {:error, :truncated}

  defp read_script(binary) do
    with {:ok, size, rest} <- read_varint(binary) do
      case rest do
        <<script::binary-size(size), rest::binary>> -> {:ok, script, rest}
        _ -> {:error, :truncated}
      end
    end
  end

  # --- how the txs fit together --------------------------------------------------

  defp check_transactions([], _bump_count), do: {:error, :no_transactions}

  defp check_transactions(txs, bump_count) do
    txids = Enum.map(txs, & &1.txid)
    held = MapSet.new(txids)

    cond do
      Enum.any?(txs, &(&1.bump_index != nil and &1.bump_index >= bump_count)) ->
        {:error, :bump_index_out_of_range}

      MapSet.size(held) != length(txids) ->
        {:error, :duplicate_transaction}

      true ->
        check_order(txs, held)
    end
  end

  # A tx with a BUMP stands on its own, so only a tx without one needs its
  # parents ahead of it.
  defp check_order(txs, held) do
    result =
      Enum.reduce_while(txs, MapSet.new(), fn tx, seen ->
        if tx.bump_index == nil and Enum.any?(tx.parents, &late?(&1, seen, held)),
          do: {:halt, :out_of_order},
          else: {:cont, MapSet.put(seen, tx.txid)}
      end)

    if result == :out_of_order, do: {:error, :transactions_out_of_order}, else: :ok
  end

  defp late?(parent, seen, held),
    do: MapSet.member?(held, parent) and not MapSet.member?(seen, parent)

  defp check_atomic(nil, _txs), do: :ok

  defp check_atomic(subject, txs) do
    by_txid = Map.new(txs, &{&1.txid, &1})

    cond do
      not Map.has_key?(by_txid, subject) ->
        {:error, :atomic_subject_missing}

      MapSet.size(ancestry([subject], by_txid, MapSet.new())) != length(txs) ->
        {:error, :atomic_unrelated_transaction}

      true ->
        :ok
    end
  end

  defp ancestry([], _by_txid, seen), do: seen

  defp ancestry([txid | queue], by_txid, seen) do
    case {MapSet.member?(seen, txid), by_txid} do
      {false, %{^txid => tx}} ->
        ancestry(proof_stops(tx) ++ queue, by_txid, MapSet.put(seen, txid))

      _ ->
        ancestry(queue, by_txid, seen)
    end
  end

  defp proof_stops(%{bump_index: nil, parents: parents}), do: parents
  defp proof_stops(_tx_with_bump), do: []

  # --- bytes -------------------------------------------------------------------

  defp read_many(count, rest, reader), do: read_many(count, rest, reader, [])

  defp read_many(0, rest, _reader, acc), do: {:ok, Enum.reverse(acc), rest}

  defp read_many(count, rest, reader, acc) do
    case reader.(rest) do
      {:ok, item, rest} -> read_many(count - 1, rest, reader, [item | acc])
      {:error, _} = error -> error
    end
  end

  defp read_varint(<<n, rest::binary>>) when n < 0xFD, do: {:ok, n, rest}
  defp read_varint(<<0xFD, n::little-16, rest::binary>>) when n >= 0xFD, do: {:ok, n, rest}
  defp read_varint(<<0xFE, n::little-32, rest::binary>>) when n > 0xFFFF, do: {:ok, n, rest}
  defp read_varint(<<0xFF, n::little-64, rest::binary>>) when n > 0xFFFFFFFF, do: {:ok, n, rest}
  defp read_varint(<<0xFD, _::little-16, _::binary>>), do: {:error, :varint_not_minimal}
  defp read_varint(<<0xFE, _::little-32, _::binary>>), do: {:error, :varint_not_minimal}
  defp read_varint(<<0xFF, _::little-64, _::binary>>), do: {:error, :varint_not_minimal}
  defp read_varint(_), do: {:error, :truncated}

  defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))

  defp internal(hex), do: hex |> Base.decode16!(case: :mixed) |> reverse()

  defp display(bytes), do: bytes |> reverse() |> Base.encode16(case: :lower)

  defp reverse(bytes),
    do: bytes |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
end
