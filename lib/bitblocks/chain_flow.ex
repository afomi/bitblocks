defmodule Bitblocks.ChainFlow do
  @moduledoc """
  The transaction graph for a range of blocks, for the `/tx-graph` flow
  space: every stored tx in the range, every output with the height that
  spent it, and every input as an edge back to the output it spends.

  Values come from each row's raw hex (`Chain.RawTx.flows/1`), exact
  satoshis. Spends come from `spend_index`, so "unspent" means "no spend
  stored yet": the answer carries `spends_known_through`
  (`Sync.complete_through/0`), and a later spend is as visible as our sync.

  An input whose source is outside the range is an edge from an `external`
  node: the source txid and its height when we hold it.

  ## Payload (compact, arrays not objects, for ranges of tens of thousands of txs)

      blocks:   [[height, time, num_tx, stored_txs], ...]          height order
      txs:      [[height, txid, coinbase 0|1, n_in, sats_out], ...] block order
      outputs:  [[[sats, spent_height | -1], ...], ...]             one list per tx
      edges:    [[source, vout, target, sats | -1], ...]            source >= 0 is a tx index;
                                                                    -1 - i is external[i]
      external: [[txid, height | -1], ...]

  Reads are capped (`:max_blocks`, `:max_txs`) and run under a statement
  timeout; a range over the cap is cut at a block boundary and says so
  (`truncated: true`, `to` is the last block read).
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, RawTx, Transaction}
  alias Bitblocks.ChainScrubber
  alias Bitblocks.Repo

  @max_blocks 5_000
  @max_txs 50_000
  @timeout_ms 8_000

  def max_blocks, do: @max_blocks
  def max_txs, do: @max_txs

  @spec range(non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, :timeout | :invalid_range}
  def range(from, to, opts \\ [])

  def range(from, to, opts)
      when is_integer(from) and is_integer(to) and from >= 0 and to >= from do
    max_blocks = Keyword.get(opts, :max_blocks, @max_blocks)
    max_txs = Keyword.get(opts, :max_txs, @max_txs)
    to = min(to, from + max_blocks - 1)

    case ChainScrubber.with_statement_timeout(Keyword.get(opts, :timeout_ms, @timeout_ms), fn ->
           build(from, to, max_txs)
         end) do
      {:ok, payload} -> {:ok, payload}
      {:error, _} -> {:error, :timeout}
    end
  end

  def range(_from, _to, _opts), do: {:error, :invalid_range}

  defp build(from, to, max_txs) do
    blocks =
      Repo.all(
        from b in Block,
          where: b.height >= ^from and b.height <= ^to,
          order_by: [asc: b.height],
          select: %{height: b.height, hash: b.hash, time: b.time, num_tx: b.num_tx, tx: b.tx}
      )

    rows =
      Repo.all(
        from t in Transaction,
          where: t.block_height >= ^from and t.block_height <= ^to,
          order_by: [asc: t.block_height],
          limit: ^(max_txs + 1),
          select: %{txid: t.txid, height: t.block_height, raw: t.raw, coinbase: t.coinbase}
      )

    {rows, blocks, to, truncated?} = cut(rows, blocks, to, max_txs)

    rows = order_within_blocks(rows, blocks)
    index = rows |> Enum.with_index() |> Map.new(fn {r, i} -> {r.txid, i} end)
    flows = Enum.map(rows, &parse/1)

    spent = spent_heights(Map.keys(index))

    wanted =
      for {:ok, %{inputs: inputs}} <- flows,
          {txid, _vout} <- inputs,
          not Map.has_key?(index, txid),
          uniq: true,
          do: txid

    sources = external_sources(wanted)
    external = Enum.with_index(wanted)
    ext_index = Map.new(external, fn {txid, i} -> {txid, i} end)

    outputs_of =
      for {row, flow} <- Enum.zip(rows, flows), into: %{} do
        {row.txid, output_values(flow)}
      end

    txs =
      Enum.zip_with(rows, flows, fn row, flow ->
        {n_in, sats_out} =
          case flow do
            {:ok, %{inputs: inputs, outputs: outs}} ->
              {if(coinbase?(flow), do: 0, else: length(inputs)),
               outs |> Enum.map(&elem(&1, 0)) |> Enum.sum()}

            :error ->
              {0, -1}
          end

        [
          row.height,
          row.txid,
          if(row.coinbase || coinbase?(flow), do: 1, else: 0),
          n_in,
          sats_out
        ]
      end)

    outputs =
      Enum.map(rows, fn row ->
        outputs_of[row.txid]
        |> Enum.with_index()
        |> Enum.map(fn {sats, vout} -> [sats, Map.get(spent, {row.txid, vout}, -1)] end)
      end)

    edges =
      for {{:ok, %{inputs: inputs}} = flow, target} <- Enum.with_index(flows),
          not coinbase?(flow),
          {txid, vout} <- inputs do
        case index do
          %{^txid => source} ->
            [source, vout, target, value_at(outputs_of[txid], vout)]

          _ ->
            [
              -1 - ext_index[txid],
              vout,
              target,
              value_at(Map.get(sources, txid, %{})[:values], vout)
            ]
        end
      end

    stored = Enum.frequencies_by(rows, & &1.height)

    %{
      from: from,
      to: to,
      truncated: truncated?,
      max_txs: max_txs,
      spends_known_through: complete_through(),
      blocks:
        Enum.map(
          blocks,
          &[&1.height, &1.time || 0, &1.num_tx || 0, Map.get(stored, &1.height, 0)]
        ),
      txs: txs,
      outputs: outputs,
      edges: edges,
      external:
        Enum.map(external, fn {txid, _} ->
          [txid, get_in(sources, [txid, :height]) || -1]
        end)
    }
  end

  # Over the tx cap: drop the last (possibly partial) block, so every block
  # shown is whole.
  defp cut(rows, blocks, to, max_txs) when length(rows) <= max_txs, do: {rows, blocks, to, false}

  defp cut(rows, blocks, _to, max_txs) do
    last = rows |> Enum.at(max_txs) |> Map.fetch!(:height)
    last = max(last - 1, rows |> hd() |> Map.fetch!(:height))
    rows = Enum.filter(rows, &(&1.height <= last))
    {rows, Enum.filter(blocks, &(&1.height <= last)), last, true}
  end

  # A block's txs in their order in the block (`blocks.tx`, when it is kept),
  # else coinbase first and then by txid, so the layout is stable either way.
  defp order_within_blocks(rows, blocks) do
    positions =
      for %{height: h, tx: txids} <- blocks,
          is_list(txids),
          {txid, i} <- Enum.with_index(txids),
          into: %{} do
        {{h, txid}, i}
      end

    Enum.sort_by(rows, fn r ->
      {r.height, Map.get(positions, {r.height, r.txid}, :infinity),
       if(r.coinbase, do: 0, else: 1), r.txid}
    end)
  end

  defp parse(%{raw: raw}) when is_binary(raw) do
    case RawTx.flows(raw) do
      {:ok, flows} -> {:ok, flows}
      _ -> :error
    end
  end

  defp parse(_), do: :error

  defp coinbase?({:ok, %{inputs: [:coinbase]}}), do: true
  defp coinbase?(_), do: false

  defp output_values({:ok, %{outputs: outs}}), do: Enum.map(outs, &elem(&1, 0))
  defp output_values(:error), do: []

  defp value_at(values, vout) when is_list(values) do
    case Enum.at(values, vout) do
      v when is_integer(v) -> v
      _ -> -1
    end
  end

  defp value_at(_values, _vout), do: -1

  # {txid, vout} => the height of the tx that spent it, for outputs of these txs.
  defp spent_heights([]), do: %{}

  defp spent_heights(txids) do
    txids
    |> Enum.chunk_every(5_000)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from s in "spend_index",
          join: t in Transaction,
          on: t.txid == s.spending_txid,
          where: s.txid in ^chunk,
          select: {s.txid, s.vout, t.block_height}
      )
    end)
    |> Map.new(fn {txid, vout, h} -> {{txid, vout}, h || -1} end)
  end

  # Source txs outside the range: their height and output values, when stored.
  defp external_sources([]), do: %{}

  defp external_sources(txids) do
    txids
    |> Enum.chunk_every(5_000)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from t in Transaction,
          where: t.txid in ^chunk,
          select: %{txid: t.txid, height: t.block_height, raw: t.raw}
      )
    end)
    |> Map.new(fn row -> {row.txid, %{height: row.height, values: output_values(parse(row))}} end)
  end

  defp complete_through do
    Bitblocks.Sync.complete_through()
  rescue
    _ -> nil
  end
end
