defmodule Bitblocks.Chain.TxGraph do
  @moduledoc """
  The transactions around one tx, for `/graph`: what it spends (negative
  levels) and what spends it (positive levels), walked one level at a time.

  Every read is indexed, and it never loads `raw`. Going back, a row's
  `input_txids`; about a quarter of stored rows have none yet, and only those
  read their `inputs`. Going forward, `input_txids` (GIN) together with
  `spend_index`, because rows an earlier sync stored have neither until
  `Release.backfill_tx_steps/3` reaches them: until then a tx can have
  spenders this doesn't show. Each level holds at most #{100} txs, and
  `truncated` says when one was cut.

  A parent we don't store yet is still a node, with nothing behind it.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Spend, Transaction}
  alias Bitblocks.{Repo, TransactionParser}

  @max_depth 4
  @per_level 100

  @type graph :: %{nodes: [map()], edges: [map()], truncated: boolean()}

  @doc "The deepest walk `build/2` takes; a larger depth is clamped to it."
  def max_depth, do: @max_depth

  @doc "The graph around `txid`, `depth` levels each way, or `{:error, :not_found}`."
  @spec build(String.t(), integer()) :: graph() | {:error, :not_found}
  def build(txid, depth) do
    case Repo.one(from(t in Transaction, where: t.txid == ^txid, select: t.txid, limit: 1)) do
      nil ->
        {:error, :not_found}

      txid ->
        depth = depth |> max(1) |> min(@max_depth)
        start = %{nodes: %{txid => node(txid, 0)}, edges: %{}, truncated: false}

        graph =
          start
          |> walk([txid], 1, depth, -1, &parents/1)
          |> walk([txid], 1, depth, 1, &children/1)

        %{
          nodes: Map.values(graph.nodes),
          edges: Map.values(graph.edges),
          truncated: graph.truncated
        }
    end
  end

  defp walk(graph, [], _level, _depth, _sign, _step), do: graph
  defp walk(graph, _frontier, level, depth, _sign, _step) when level > depth, do: graph

  defp walk(graph, frontier, level, depth, sign, step) do
    found = step.(frontier)
    next = found |> Enum.map(fn {txid, _from, _to} -> txid end) |> Enum.uniq()
    kept = next |> Enum.take(@per_level) |> MapSet.new()
    links = Enum.filter(found, fn {txid, _from, _to} -> txid in kept end)

    new = kept |> Enum.reject(&Map.has_key?(graph.nodes, &1))

    graph =
      Enum.reduce(links, graph, fn {_txid, from, to}, acc ->
        put_in(acc, [:edges, "#{from}-#{to}"], %{id: "#{from}-#{to}", from: from, to: to})
      end)

    graph =
      Enum.reduce(new, graph, fn txid, acc ->
        put_in(acc, [:nodes, txid], node(txid, sign * level))
      end)

    walk(
      %{graph | truncated: graph.truncated or length(next) > @per_level},
      new,
      level + 1,
      depth,
      sign,
      step
    )
  end

  # {the tx found, edge from, edge to}: value flows from a parent to its child.
  defp parents(frontier) do
    rows =
      Repo.all(
        from(t in Transaction, where: t.txid in ^frontier, select: {t.txid, t.input_txids})
      )

    {filled, unfilled} = Enum.split_with(rows, fn {_txid, input_txids} -> input_txids end)

    Enum.flat_map(filled ++ from_inputs(unfilled), fn {child, input_txids} ->
      Enum.map(input_txids, &{&1, &1, child})
    end)
  end

  defp from_inputs([]), do: []

  defp from_inputs(rows) do
    txids = Enum.map(rows, &elem(&1, 0))

    from(t in Transaction, where: t.txid in ^txids, select: {t.txid, t.inputs})
    |> Repo.all()
    |> Enum.map(fn {txid, inputs} -> {txid, TransactionParser.extract_input_txids(inputs)} end)
  end

  defp children(frontier) do
    limit = @per_level + 1

    by_input_txids =
      from(t in Transaction,
        where: fragment("? && ?::varchar[]", t.input_txids, ^frontier),
        select: {t.txid, t.input_txids},
        limit: ^limit
      )
      |> Repo.all()
      |> Enum.flat_map(fn {child, input_txids} ->
        for parent <- input_txids, parent in frontier, do: {child, parent, child}
      end)

    by_spends =
      from(s in Spend,
        where: s.txid in ^frontier,
        distinct: [s.txid, s.spending_txid],
        select: {s.spending_txid, s.txid, s.spending_txid},
        limit: ^limit
      )
      |> Repo.all()

    Enum.uniq(by_input_txids ++ by_spends)
  end

  defp node(txid, level) do
    %{id: txid, label: String.slice(txid, 0, 8) <> "...", type: "transaction", level: level}
  end
end
