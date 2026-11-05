defmodule Bitblocks.Chain.TxGraph do
  @moduledoc """
  The transactions around one tx, for `/graph`: what it spends (negative
  levels) and what spends it (positive levels), walked one level at a time.

  One query per level in each direction, on the `txid` index going back and
  the GIN index on `input_txids` going forward. It reads only those two
  columns, so no `raw` and no `inputs` are loaded. Each level holds at most
  `#{100}` txs; `truncated` says when one was cut.

  A parent we don't store yet is still a node, with nothing behind it.
  """

  import Ecto.Query

  alias Bitblocks.Chain.Transaction
  alias Bitblocks.Repo

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
    from(t in Transaction, where: t.txid in ^frontier, select: {t.txid, t.input_txids})
    |> Repo.all()
    |> Enum.flat_map(fn {child, input_txids} ->
      Enum.map(input_txids || [], &{&1, &1, child})
    end)
  end

  defp children(frontier) do
    from(t in Transaction,
      where: fragment("? && ?::varchar[]", t.input_txids, ^frontier),
      select: {t.txid, t.input_txids},
      limit: ^(@per_level + 1)
    )
    |> Repo.all()
    |> Enum.flat_map(fn {child, input_txids} ->
      for parent <- input_txids, parent in frontier, do: {child, parent, child}
    end)
  end

  defp node(txid, level) do
    %{id: txid, label: String.slice(txid, 0, 8) <> "...", type: "transaction", level: level}
  end
end
