defmodule Bitblocks.TxTypes.Candidates do
  @moduledoc """
  The shapes behind `custom` (#51, step 4 of docs/TYPING_PIPELINE.md): outputs
  no type matches, grouped by template hash and ranked, so a person can see
  which ones to name.

  An operator's tool, not a public query: `scan/3` reads the raw bytes of every
  `custom` tx in a height range, 1,000 blocks at a time, through the
  `block_height` index. It stores nothing. A range says what it covers: only
  blocks typed at the current version count, and `scan/3` reports the height
  it stopped at and any tx it couldn't read.

  Each candidate carries its template hash, outputs and txs, first height and
  txid, outputs per 10,000-block bucket, `growth` (outputs in the later half of
  the range over the earlier half; nil with none earlier), a decoded sample,
  the protocols it appears with, and example txids.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, RawTx, Transaction, TxPipeline}
  alias Bitblocks.Repo
  alias Bitblocks.Script
  alias Bitblocks.TxTypes.Classifier

  @step 1_000
  @bucket 10_000
  @examples 5
  @batch_timeout 120_000

  @doc """
  Scans blocks `from..to`. Options: `:limit` (candidates returned, default 50).

  Returns `%{from:, to:, txs:, unreadable:, candidates: [candidate]}`, most
  outputs first.
  """
  @spec scan(non_neg_integer(), non_neg_integer(), keyword()) :: map()
  def scan(from, to, opts \\ []) when is_integer(from) and is_integer(to) and from <= to do
    limit = Keyword.get(opts, :limit, 50)
    version = TxPipeline.version(:tx_types)
    middle = from + div(to - from + 1, 2)

    acc =
      from..to//@step
      |> Enum.reduce(%{shapes: %{}, txs: 0, unreadable: 0}, fn start, acc ->
        rows(start, min(start + @step - 1, to), version)
        |> Enum.reduce(acc, &tally(&1, &2, middle))
      end)

    %{
      from: from,
      to: to,
      txs: acc.txs,
      unreadable: acc.unreadable,
      candidates:
        acc.shapes
        |> Map.values()
        |> Enum.sort_by(&{-&1.outputs, &1.first_height})
        |> Enum.take(limit)
        |> Enum.map(&finish/1)
    }
  end

  defp rows(from, to, version) do
    Repo.all(
      from(t in Transaction,
        left_join: b in Block,
        on: b.hash == t.block_hash,
        where: t.block_height >= ^from and t.block_height <= ^to,
        # Typed at the version by its own stamp or its block's.
        where: t.tx_types_version == ^version or b.tx_types_version == ^version,
        where: fragment("? @> ARRAY['custom']::varchar[]", t.tx_types),
        order_by: [asc: t.block_height, asc: t.txid],
        select: %{
          txid: t.txid,
          raw: t.raw,
          block_height: t.block_height,
          protocols: t.protocols
        }
      ),
      timeout: @batch_timeout
    )
  end

  defp tally(row, acc, middle) do
    case row.raw && RawTx.parse(row.raw) do
      {:ok, tx} ->
        shapes =
          tx.outputs
          |> Enum.filter(&(Classifier.output_type(&1.script, &1.satoshis) == "custom"))
          |> Enum.reduce(acc.shapes, &count(&1, &2, row, middle))

        %{acc | shapes: shapes, txs: acc.txs + 1}

      _ ->
        %{acc | unreadable: acc.unreadable + 1, txs: acc.txs + 1}
    end
  end

  defp count(output, shapes, row, middle) do
    hash = Script.template_hash(output.script)
    later? = row.block_height >= middle
    bucket = div(row.block_height, @bucket) * @bucket

    fresh = %{
      template_hash: hash,
      outputs: 0,
      txids: MapSet.new(),
      first_height: row.block_height,
      first_txid: row.txid,
      buckets: %{},
      earlier: 0,
      later: 0,
      sample: BSV.Script.to_asm(output.script),
      protocols: MapSet.new(),
      examples: []
    }

    Map.update(shapes, hash, seen(fresh, row, bucket, later?), &seen(&1, row, bucket, later?))
  end

  defp seen(shape, row, bucket, later?) do
    %{
      shape
      | outputs: shape.outputs + 1,
        txids: MapSet.put(shape.txids, row.txid),
        buckets: Map.update(shape.buckets, bucket, 1, &(&1 + 1)),
        earlier: shape.earlier + if(later?, do: 0, else: 1),
        later: shape.later + if(later?, do: 1, else: 0),
        protocols: MapSet.union(shape.protocols, MapSet.new(row.protocols || [])),
        examples: examples(shape.examples, row.txid)
    }
  end

  defp examples(list, txid) do
    if length(list) < @examples and txid not in list, do: list ++ [txid], else: list
  end

  defp finish(shape) do
    %{
      template_hash: shape.template_hash,
      outputs: shape.outputs,
      txs: MapSet.size(shape.txids),
      first_height: shape.first_height,
      first_txid: shape.first_txid,
      per_10000_blocks: shape.buckets |> Enum.sort() |> Enum.map(&bucket/1),
      growth: if(shape.earlier > 0, do: Float.round(shape.later / shape.earlier, 2)),
      sample: shape.sample,
      protocols: shape.protocols |> MapSet.to_list() |> Enum.sort(),
      example_txids: shape.examples
    }
  end

  defp bucket({from_height, outputs}), do: %{from_height: from_height, outputs: outputs}
end
