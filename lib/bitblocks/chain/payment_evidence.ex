defmodule Bitblocks.Chain.PaymentEvidence do
  @moduledoc """
  A BRC-237 payment evidence statement (`bsv-payment-evidence/v1`), made
  distance only (#64): what a payment's ancestry shows against the headers we
  hold, in a form any reader of BRC-237 can check.

  "Distance only" is a conforming maker that runs none of section 2.3's
  checks: no script, amount or lock time is judged, so `validated` is empty,
  `lowestFeeRate` is null, and `validation` is `"none"`, or `"all"` when the
  payment is itself an anchor (U is empty). Everything else is BRC-237's: the
  walk (2.1), anchors with conditions (a) to (e), distances (2.2), status and
  conflicts as the caller observed them (2.5), the statement (3) and its
  canonical bytes (4).

  ## Material

    * `{:beef, bytes}`: a BEEF V1 or V2, bare or Atomic, framed by
      `Bitblocks.Chain.Beef.Reader`. A bare BEEF's payment is its last tx
      unless `:payment` names another.
    * `{:records, %{transactions: [raw], paths: %{txid => path}, payment:}}`:
      raw txs and their Merkle paths from our own records, each path BRC-74
      bytes (`{:brc74, bytes}`) or an Electrum-form branch
      (`{:electrum, %{"block_height", "merkle", "pos"}}`, converted as section
      6 says).

  ## Header source

  `%{headers: %{height => <<80 bytes>>}, tip: height}`; the source holds the
  tip's header. The maker trusts it, so an anchor is only as good as it.

  ## Where Bitblocks differs, on purpose

  `Beef.Reader` refuses some framings that BRC-237 would read: a VarInt not
  in its shortest form, a tx with no path placed ahead of its parent, and, in
  an Atomic BEEF, an entry beyond an anchor (BRC-237 reads BRC-95 as
  permitting it). Each is `MALFORMED` here. No published vector settles them.

  Every refusal is `{:error, code}` with a code from section 2:
  `"MALFORMED"`, `"ANCHOR_MISMATCH"`, `"CONFLICT"` or `"OVER_BOUND"`.
  """

  import Bitwise

  alias Bitblocks.Chain.Beef.Reader

  @version "bsv-payment-evidence/v1"

  @bounds %{
    max_transactions: 1_000,
    max_distance: 100,
    max_material_bytes: 32_000_000,
    max_statement_bytes: 1_000_000
  }

  @events ~w(received signed-locally handed-to-broadcaster seen-by-network)
  @max_sats 2_100_000_000_000_000

  @type material :: {:beef, binary()} | {:records, map()}
  @type header_source :: %{headers: %{non_neg_integer() => binary()}, tip: non_neg_integer()}
  @type code :: String.t()

  @doc "The bounds `make/3` applies unless given others (BRC-237's suggested values)."
  def bounds, do: @bounds

  @doc """
  Makes the statement: `{:ok, canonical_bytes}` or `{:error, code}`.

  Options: `:made_at` (Unix seconds, default now), `:event` (one of
  `received`, the default, `signed-locally`, `handed-to-broadcaster` or
  `seen-by-network`; `mined` is said only when the payment is an anchor),
  `:conflicts` (a conflict observation as section 2.5 gives it, default
  `%{"checked" => false}`), `:payment` (a bare BEEF's payment txid), and any
  of `bounds/0`'s keys.
  """
  @spec make(material(), header_source(), keyword()) :: {:ok, binary()} | {:error, code()}
  def make(material, header_source, opts \\ []) do
    bounds = Map.merge(@bounds, Map.new(Keyword.take(opts, Map.keys(@bounds))))

    with {:ok, held, payment} <- frame(material, bounds, opts),
         {:ok, walk} <- walk(held, payment, header_source, bounds),
         :ok <- records_bound(material, walk, held, bounds),
         :ok <- check_conflicts(walk, held),
         {:ok, distances} <- distances(walk, held, payment, bounds),
         statement = statement(walk, distances, payment, header_source, opts),
         bytes = canonical(statement),
         :ok <- bounded(byte_size(bytes), bounds.max_statement_bytes) do
      {:ok, bytes}
    end
  end

  # --- material ------------------------------------------------------------------

  # `held` is txid => %{raw:, tx:, path:} for every entry the material holds
  # bytes for (`path` is a Reader BUMP or nil).
  defp frame({:beef, bytes}, bounds, opts) do
    limits = [
      max_bytes: bounds.max_material_bytes,
      max_bumps: :infinity,
      max_transactions: :infinity,
      max_leaves: :infinity
    ]

    case Reader.parse(bytes, limits) do
      {:ok, beef} ->
        # An Atomic BEEF's subject is the payment (BRC-95); a bare one's is named.
        payment = if beef.atomic, do: beef.subject, else: opts[:payment] || beef.subject

        if beef.atomic and opts[:payment] not in [nil, payment] do
          malformed()
        else
          with {:ok, held} <- hold(beef.transactions, &bump(beef.bumps, &1)),
               do: held_or_missing(held, payment)
        end

      {:error, :too_large} ->
        {:error, "OVER_BOUND"}

      {:error, _} ->
        malformed()
    end
  end

  defp frame({:records, %{transactions: raws, paths: paths, payment: payment}}, _bounds, _opts) do
    with {:ok, txs} <- records_txs(raws),
         {:ok, bumps} <- records_paths(paths, Map.new(txs, &{&1.txid, &1.raw})),
         {:ok, held} <- hold(txs, &Map.get(bumps, &1.txid)) do
      held_or_missing(held, payment)
    end
  end

  defp frame(_material, _bounds, _opts), do: malformed()

  defp bump(_bumps, %{bump_index: nil}), do: nil
  defp bump(bumps, %{bump_index: i}), do: Enum.at(bumps, i)

  defp records_txs(raws) do
    Enum.reduce_while(raws, {:ok, []}, fn raw, {:ok, acc} ->
      case decode(raw) do
        {:ok, _tx} -> {:cont, {:ok, [%{txid: Reader.txid(raw), raw: raw} | acc]}}
        :error -> {:halt, malformed()}
      end
    end)
    |> case do
      {:ok, txs} ->
        if length(Enum.uniq_by(txs, & &1.txid)) == length(txs),
          do: {:ok, Enum.reverse(txs)},
          else: malformed()

      error ->
        error
    end
  end

  defp records_paths(paths, raws) do
    Enum.reduce_while(paths, {:ok, %{}}, fn {txid, path}, {:ok, acc} ->
      with {:ok, bytes} <- path_bytes(path, raws[txid]),
           {:ok, bump, <<>>} <- Reader.parse_bump(bytes) do
        {:cont, {:ok, Map.put(acc, txid, Map.put(bump, :bytes, byte_size(bytes)))}}
      else
        _ -> {:halt, malformed()}
      end
    end)
  end

  defp path_bytes({:brc74, bytes}, _raw) when is_binary(bytes), do: {:ok, bytes}

  defp path_bytes({:electrum, branch}, raw) when is_binary(raw),
    do: electrum_to_brc74(branch, raw)

  defp path_bytes(_path, _raw), do: :error

  defp hold(txs, path_of) do
    Enum.reduce_while(txs, {:ok, %{}}, fn
      %{raw: nil}, acc ->
        {:cont, acc}

      %{txid: txid, raw: raw} = entry, {:ok, acc} ->
        case decode(raw) do
          {:ok, tx} ->
            {:cont, {:ok, Map.put(acc, txid, %{raw: raw, tx: tx, path: path_of.(entry)})}}

          :error ->
            {:halt, malformed()}
        end
    end)
  end

  defp held_or_missing(held, payment) do
    if Map.has_key?(held, payment), do: {:ok, held, payment}, else: malformed()
  end

  # Decoded completely: no byte left over, at least one input and one output.
  defp decode(raw) do
    case BSV.Serializable.parse(%BSV.Tx{}, raw) do
      {:ok, %BSV.Tx{inputs: [_ | _], outputs: [_ | _]} = tx, <<>>} -> {:ok, tx}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # For records, the bound counts what the walk read: each visited tx's bytes
  # and its path's, as BRC-74 bytes. A BEEF's whole length was bounded framing it.
  defp records_bound({:records, _}, walk, held, bounds) do
    walk.seen
    |> Enum.map(fn txid ->
      %{raw: raw, path: path} = held[txid]
      byte_size(raw) + if(path, do: path.bytes, else: 0)
    end)
    |> Enum.sum()
    |> bounded(bounds.max_material_bytes)
  end

  defp records_bound(_material, _walk, _held, _bounds), do: :ok

  # --- the walk (2.1) ------------------------------------------------------------

  defp walk(held, payment, header_source, bounds) do
    do_walk([payment], held, header_source, bounds, %{
      seen: MapSet.new(),
      anchors: %{},
      unconfirmed: MapSet.new(),
      unresolved: MapSet.new()
    })
  end

  defp do_walk([], _held, _hs, _bounds, walk), do: {:ok, walk}

  defp do_walk([txid | queue], held, hs, bounds, walk) do
    cond do
      MapSet.member?(walk.seen, txid) ->
        do_walk(queue, held, hs, bounds, walk)

      MapSet.size(walk.seen) >= bounds.max_transactions ->
        {:error, "OVER_BOUND"}

      true ->
        entry = Map.fetch!(held, txid)
        walk = %{walk | seen: MapSet.put(walk.seen, txid)}

        with :ok <- permitted(entry.path),
             {:ok, kind} <- anchor(txid, entry, hs) do
          case kind do
            {:anchor, height, block_hash} ->
              anchor = %{"blockHash" => block_hash, "height" => height, "txid" => txid}

              do_walk(queue, held, hs, bounds, %{
                walk
                | anchors: Map.put(walk.anchors, txid, anchor)
              })

            :unconfirmed ->
              with {:ok, next, unresolved} <- follow(entry.tx, held) do
                walk = %{
                  walk
                  | unconfirmed: MapSet.put(walk.unconfirmed, txid),
                    unresolved: MapSet.union(walk.unresolved, unresolved)
                }

                do_walk(next ++ queue, held, hs, bounds, walk)
              end
          end
        end
    end
  end

  # Each input to the tx it spends, or recorded as unresolved.
  defp follow(%BSV.Tx{inputs: inputs}, held) do
    Enum.reduce_while(inputs, {:ok, [], MapSet.new()}, fn input, {:ok, next, unresolved} ->
      {txid, vout} = outpoint(input)

      case held do
        %{^txid => %{tx: %BSV.Tx{outputs: outputs}}} when vout < length(outputs) ->
          {:cont, {:ok, [txid | next], unresolved}}

        %{^txid => _} ->
          {:halt, malformed()}

        _ ->
          {:cont, {:ok, next, MapSet.put(unresolved, {txid, vout})}}
      end
    end)
  end

  defp outpoint(%BSV.TxIn{outpoint: op}), do: {BSV.OutPoint.get_txid(op), op.vout}

  # --- anchors (section 1) --------------------------------------------------------

  defp anchor(_txid, %{path: nil}, _hs), do: {:ok, :unconfirmed}

  defp anchor(txid, %{path: path, raw: raw}, %{headers: headers, tip: tip}) do
    header = path.height <= tip && Map.get(headers, path.height)

    cond do
      # Condition (b) unmet: the path isn't checked, and the tx is as if it had none.
      not is_binary(header) ->
        {:ok, :unconfirmed}

      byte_size(raw) == 64 ->
        {:error, "ANCHOR_MISMATCH"}

      true ->
        <<_::binary-size(36), merkle_root::binary-size(32), _::binary>> = header

        case own_root(path, internal(txid)) do
          {:ok, ^merkle_root} -> {:ok, {:anchor, path.height, display(sha256d(header))}}
          _ -> {:error, "ANCHOR_MISMATCH"}
        end
    end
  end

  # The fold of a txid's own path: exactly the tree height of steps, none for a
  # one-transaction block, and no step that hashes 64 bytes decoding as a tx.
  defp own_root(%{path: [[%{offset: 0, hash: leaf}]]}, leaf), do: {:ok, leaf}

  defp own_root(%{path: levels} = path, leaf) do
    nodes = nodes(path)

    with x when is_integer(x) <- offset_of(levels, leaf) do
      levels
      |> length()
      |> then(&Range.new(0, &1 - 1))
      |> Enum.reduce_while({:ok, leaf}, fn i, {:ok, working} ->
        mine = x >>> i

        case Map.get(nodes, {i, bxor(mine, 1)}) do
          nil ->
            {:halt, :no_root}

          sibling ->
            sibling = if sibling == :duplicate, do: working, else: sibling
            pair = if band(mine, 1) == 0, do: working <> sibling, else: sibling <> working

            if decodes_as_tx?(pair), do: {:halt, :decodes}, else: {:cont, {:ok, sha256d(pair)}}
        end
      end)
    else
      _ -> :no_root
    end
  end

  defp offset_of([leaves | _], leaf) do
    leaves
    |> Enum.filter(&(&1.hash == leaf))
    |> Enum.map(& &1.offset)
    |> Enum.min(fn -> nil end)
  end

  # Every node a path states or implies, `{level, offset} => hash | :duplicate`
  # (a duplicate at level 0 stands for the working hash, resolved in the fold).
  defp nodes(%{path: levels}) do
    levels
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {leaves, level}, nodes ->
      stated = Map.new(leaves, &{{level, &1.offset}, stated(&1)})
      Map.merge(nodes, Map.merge(implied(nodes, level), stated))
    end)
  end

  defp stated(%{duplicate: true}), do: :duplicate
  defp stated(%{hash: hash}), do: hash

  # The nodes at `level` computed from pairs at `level - 1` where both are known.
  defp implied(_nodes, 0), do: %{}

  defp implied(nodes, level) do
    for {{l, offset}, _} <- nodes,
        l == level - 1,
        band(offset, 1) == 0,
        {:ok, value} <- [pair_hash(nodes, l, offset)],
        into: %{},
        do: {{level, offset >>> 1}, value}
  end

  defp pair_hash(nodes, level, left_offset) do
    with left when is_binary(left) <- Map.get(nodes, {level, left_offset}),
         right when not is_nil(right) <- Map.get(nodes, {level, left_offset + 1}) do
      right = if right == :duplicate, do: left, else: right
      {:ok, sha256d(left <> right)}
    else
      _ -> :error
    end
  end

  # BRC-74's rules a framer can't see (2.1): a node stated as a hash, or as the
  # duplicate of its sibling, must equal the node its two children give.
  defp permitted(nil), do: :ok

  defp permitted(%{path: levels}) do
    levels
    |> Enum.with_index()
    |> Enum.reduce_while(%{}, fn {leaves, level}, nodes ->
      implied = implied(nodes, level)
      stated = Map.new(leaves, &{{level, &1.offset}, stated(&1)})
      merged = Map.merge(nodes, Map.merge(implied, stated))

      if Enum.all?(stated, &agrees?(&1, implied, merged)),
        do: {:cont, merged},
        else: {:halt, :conflict}
    end)
    |> case do
      :conflict -> malformed()
      _ -> :ok
    end
  end

  defp agrees?({key, value}, implied, merged) do
    case Map.fetch(implied, key) do
      :error ->
        true

      {:ok, computed} when value == :duplicate ->
        {level, offset} = key
        Map.get(merged, {level, bxor(offset, 1)}) == computed

      {:ok, computed} ->
        value == computed
    end
  end

  # 64 bytes that read, in the standard serialization, as a transaction ending
  # at byte 64 (section 1), VarInts in any of their forms.
  @doc false
  def decodes_as_tx?(<<_version::binary-size(4), rest::binary>>) when byte_size(rest) == 60 do
    with {:ok, n_in, rest} when n_in >= 1 <- varint(rest),
         {:ok, rest} <- many(n_in, rest, &input/1),
         {:ok, n_out, rest} when n_out >= 1 <- varint(rest),
         {:ok, rest, _sum} <- outputs(n_out, rest, 0),
         <<_lock_time::binary-size(4)>> <- rest do
      true
    else
      _ -> false
    end
  end

  def decodes_as_tx?(_), do: false

  defp input(<<_prev::binary-size(36), rest::binary>>) do
    with {:ok, len, rest} <- varint(rest),
         <<_script::binary-size(len), _seq::binary-size(4), rest::binary>> <- rest do
      {:ok, rest}
    else
      _ -> :error
    end
  end

  defp input(_), do: :error

  defp outputs(0, rest, sum), do: {:ok, rest, sum}

  defp outputs(n, <<value::little-64, rest::binary>>, sum)
       when value <= @max_sats and sum + value <= @max_sats do
    with {:ok, len, rest} <- varint(rest),
         <<_script::binary-size(len), rest::binary>> <- rest do
      outputs(n - 1, rest, sum + value)
    else
      _ -> :error
    end
  end

  defp outputs(_n, _rest, _sum), do: :error

  defp many(0, rest, _fun), do: {:ok, rest}

  defp many(n, rest, fun) do
    case fun.(rest) do
      {:ok, rest} -> many(n - 1, rest, fun)
      :error -> :error
    end
  end

  defp varint(<<n, rest::binary>>) when n < 0xFD, do: {:ok, n, rest}
  defp varint(<<0xFD, n::little-16, rest::binary>>), do: {:ok, n, rest}
  defp varint(<<0xFE, n::little-32, rest::binary>>), do: {:ok, n, rest}
  defp varint(<<0xFF, n::little-64, rest::binary>>), do: {:ok, n, rest}
  defp varint(_), do: :error

  # --- conflicts and distances (2.1, 2.2) ------------------------------------------

  defp check_conflicts(walk, held) do
    spent_by_u = for txid <- walk.unconfirmed, input <- held[txid].tx.inputs, do: outpoint(input)

    spent_by_anchors =
      for {txid, _} <- walk.anchors, input <- held[txid].tx.inputs, do: outpoint(input)

    if length(Enum.uniq(spent_by_u)) != length(spent_by_u) or
         Enum.any?(spent_by_u, &(&1 in spent_by_anchors)),
       do: {:error, "CONFLICT"},
       else: :ok
  end

  defp distances(walk, held, payment, bounds) do
    sources = fn txid ->
      for input <- held[txid].tx.inputs,
          {src, _} = outpoint(input),
          Map.has_key?(held, src),
          do: src
    end

    # Longest run of U transactions from each tx back through U.
    longest =
      memo(
        fn txid, rec ->
          1 +
            (sources.(txid) |> Enum.filter(&(&1 in walk.unconfirmed)) |> Enum.map(rec) |> max0())
        end,
        fn longest -> walk.unconfirmed |> Enum.map(longest) |> max0() end
      )

    if longest > bounds.max_distance do
      {:error, "OVER_BOUND"}
    else
      {:ok, distance_fields(walk, sources, payment)}
    end
  end

  defp distance_fields(walk, sources, payment) do
    if Map.has_key?(walk.anchors, payment) do
      %{max: 0, min: 0}
    else
      to_anchor = fn pick ->
        memo(
          fn txid, rec ->
            txid
            |> sources.()
            |> Enum.map(fn src -> if Map.has_key?(walk.anchors, src), do: 0, else: rec.(src) end)
            |> Enum.reject(&is_nil/1)
            |> then(&if &1 == [], do: nil, else: 1 + pick.(&1))
          end,
          & &1.(payment)
        )
      end

      %{
        max: if(MapSet.size(walk.unresolved) == 0, do: to_anchor.(&Enum.max/1)),
        min: to_anchor.(&Enum.min/1)
      }
    end
  end

  defp max0([]), do: 0
  defp max0(list), do: Enum.max(list)

  # A memoised recursion over the ancestry, a DAG (txids can't form a cycle):
  # `fun.(txid, rec)` computes one tx's value, calling `rec` for its sources;
  # `body` gets the memoised function and returns the answer.
  defp memo(fun, body) do
    table = :ets.new(:payment_evidence_memo, [:set, :private])

    rec = fn rec, txid ->
      case :ets.lookup(table, txid) do
        [{_, value}] ->
          value

        [] ->
          value = fun.(txid, &rec.(rec, &1))
          :ets.insert(table, {txid, value})
          value
      end
    end

    try do
      body.(&rec.(rec, &1))
    after
      :ets.delete(table)
    end
  end

  # --- the statement (3) and its canonical form (4) -----------------------------------

  defp statement(walk, distances, payment, %{headers: headers, tip: tip}, opts) do
    anchor = walk.anchors[payment]
    event = opts[:event] || "received"

    if event not in @events,
      do: raise(ArgumentError, "event must be one of #{inspect(@events)}, not #{inspect(event)}")

    %{
      "anchors" => walk.anchors |> Map.values() |> Enum.sort_by(& &1["txid"]),
      "conflicts" => opts[:conflicts] || %{"checked" => false},
      "distanceMax" => distances.max,
      "distanceMin" => distances.min,
      "fullyAnchored" => MapSet.size(walk.unresolved) == 0,
      "lowestFeeRate" => nil,
      "madeAt" => opts[:made_at] || System.os_time(:second),
      "status" =>
        if(anchor,
          do: %{"depth" => tip - anchor["height"] + 1, "event" => "mined"},
          else: %{"depth" => nil, "event" => event}
        ),
      "tip" => %{"blockHash" => display(sha256d(Map.fetch!(headers, tip))), "height" => tip},
      "txid" => payment,
      "unconfirmed" => walk.unconfirmed |> MapSet.to_list() |> Enum.sort(),
      "unresolved" =>
        walk.unresolved
        |> Enum.sort()
        |> Enum.map(fn {txid, vout} -> %{"txid" => txid, "vout" => vout} end),
      "validated" => [],
      "validation" => if(MapSet.size(walk.unconfirmed) == 0, do: "all", else: "none"),
      "version" => @version
    }
  end

  @doc """
  The canonical form of section 4: keys sorted by their bytes at every level,
  no whitespace. Every string a statement holds needs no escaping.
  """
  @spec canonical(term()) :: binary()
  def canonical(map) when is_map(map) do
    body =
      map
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map_join(",", fn {key, value} -> canonical(key) <> ":" <> canonical(value) end)

    "{" <> body <> "}"
  end

  def canonical(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"
  def canonical(nil), do: "null"
  def canonical(true), do: "true"
  def canonical(false), do: "false"
  def canonical(n) when is_integer(n) and n >= 0, do: Integer.to_string(n)
  def canonical(s) when is_binary(s), do: ~s("#{s}")

  # --- Electrum-form branches (6) ----------------------------------------------------

  @doc """
  An Electrum-form branch as BRC-74 bytes, for the tx `raw`, as section 6
  writes it; `:error` for a branch section 6 refuses.
  """
  @spec electrum_to_brc74(map(), binary()) :: {:ok, binary()} | :error
  def electrum_to_brc74(%{"block_height" => h, "merkle" => merkle, "pos" => p} = branch, raw)
      when map_size(branch) == 3 and is_integer(h) and h >= 0 and h < 1 <<< 64 and
             is_integer(p) and p >= 0 and is_list(merkle) and length(merkle) <= 64 do
    n = length(merkle)

    with true <- p < 1 <<< n,
         {:ok, siblings} <- siblings(merkle),
         {:ok, _tx} <- decode(raw) do
      txid = sha256d(raw)
      {:ok, write_path(h, n, p, txid, siblings)}
    else
      _ -> :error
    end
  end

  def electrum_to_brc74(_branch, _raw), do: :error

  defp siblings(merkle) do
    if Enum.all?(merkle, &(is_binary(&1) and &1 =~ ~r/\A[0-9a-f]{64}\z/)),
      do: {:ok, Enum.map(merkle, &internal/1)},
      else: :error
  end

  defp write_path(h, 0, _p, txid, []), do: varint_bytes(h) <> <<1>> <> <<1>> <> <<0, 2>> <> txid

  defp write_path(h, n, p, txid, siblings) do
    {levels, _working} =
      siblings
      |> Enum.with_index()
      |> Enum.map_reduce(txid, fn {sibling, i}, working ->
        mine = p >>> i
        at = bxor(mine, 1)
        dup? = sibling == working and band(mine, 1) == 0
        node = varint_bytes(at) <> if(dup?, do: <<1>>, else: <<0>> <> sibling)
        pair = if band(mine, 1) == 0, do: working <> sibling, else: sibling <> working
        {{at, node}, sha256d(pair)}
      end)

    [{at0, node0} | rest] = levels
    tx_node = varint_bytes(p) <> <<2>> <> txid
    level0 = if p < at0, do: tx_node <> node0, else: node0 <> tx_node

    varint_bytes(h) <>
      <<n>> <>
      <<2>> <>
      level0 <>
      Enum.map_join(rest, fn {_at, node} -> <<1>> <> node end)
  end

  defp varint_bytes(n) when n < 0xFD, do: <<n>>
  defp varint_bytes(n) when n <= 0xFFFF, do: <<0xFD, n::little-16>>
  defp varint_bytes(n) when n <= 0xFFFFFFFF, do: <<0xFE, n::little-32>>
  defp varint_bytes(n), do: <<0xFF, n::little-64>>

  # --- helpers ---------------------------------------------------------------------

  defp bounded(size, bound) when size <= bound, do: :ok
  defp bounded(_size, _bound), do: {:error, "OVER_BOUND"}

  defp malformed, do: {:error, "MALFORMED"}

  defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))
  defp internal(hex), do: hex |> Base.decode16!(case: :lower) |> reverse()
  defp display(bytes), do: bytes |> reverse() |> Base.encode16(case: :lower)

  defp reverse(bytes),
    do: bytes |> :binary.bin_to_list() |> Enum.reverse() |> :erlang.list_to_binary()
end
