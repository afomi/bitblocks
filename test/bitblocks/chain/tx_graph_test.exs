defmodule Bitblocks.Chain.TxGraphTest do
  # The graph around a tx, walked level by level on indexes: it never reads
  # `raw` or `inputs`, and costs one query a level each way.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.TxGraph

  defp tx!(attrs \\ %{}), do: transaction_fixture(attrs)

  defp levels(graph), do: Map.new(graph.nodes, &{&1.id, &1.level})
  defp edges(graph), do: graph.edges |> Enum.map(&{&1.from, &1.to}) |> Enum.sort()

  defp queries(fun) do
    test_pid = self()
    id = "tx-graph-#{inspect(test_pid)}"

    :telemetry.attach(
      id,
      [:bitblocks, :repo, :query],
      fn _event, _measure, meta, _ ->
        if self() == test_pid, do: send(test_pid, {:query, meta.query})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(id)
    {result, drain([])}
  end

  defp drain(acc) do
    receive do
      {:query, q} -> drain([q | acc])
    after
      0 -> acc
    end
  end

  test "walks back through what it spends and forward through what spends it" do
    grandparent = tx!()
    parent = tx!(%{input_txids: [grandparent.txid]})
    center = tx!(%{input_txids: [parent.txid]})
    child = tx!(%{input_txids: [center.txid]})
    grandchild = tx!(%{input_txids: [child.txid]})
    tx!()

    graph = TxGraph.build(center.txid, 2)

    assert levels(graph) == %{
             grandparent.txid => -2,
             parent.txid => -1,
             center.txid => 0,
             child.txid => 1,
             grandchild.txid => 2
           }

    assert edges(graph) ==
             Enum.sort([
               {grandparent.txid, parent.txid},
               {parent.txid, center.txid},
               {center.txid, child.txid},
               {child.txid, grandchild.txid}
             ])

    refute graph.truncated
  end

  test "a parent we don't store is still a node" do
    center = tx!(%{input_txids: ["missing-parent"]})

    graph = TxGraph.build(center.txid, 2)

    assert levels(graph)["missing-parent"] == -1
  end

  test "stops at the depth asked for, and clamps a larger one" do
    center = tx!()
    child = tx!(%{input_txids: [center.txid]})
    grandchild = tx!(%{input_txids: [child.txid]})

    assert levels(TxGraph.build(center.txid, 1)) |> Map.has_key?(child.txid)
    refute levels(TxGraph.build(center.txid, 1)) |> Map.has_key?(grandchild.txid)
    assert %{nodes: [_, _, _]} = TxGraph.build(center.txid, 999)
  end

  test "a spend that loops back doesn't walk forever" do
    a = tx!(%{txid: "loop-a", input_txids: ["loop-b"]})
    tx!(%{txid: "loop-b", input_txids: ["loop-a"]})

    assert %{nodes: [_, _]} = TxGraph.build(a.txid, 4)
  end

  test "cuts a level at 100 and says so" do
    center = tx!()
    for _ <- 1..101, do: tx!(%{input_txids: [center.txid]})

    graph = TxGraph.build(center.txid, 1)

    assert graph.truncated
    assert length(graph.nodes) == 101
  end

  test "reads no raw or inputs, and costs one query a level each way" do
    grandparent = tx!()
    parent = tx!(%{input_txids: [grandparent.txid]})
    center = tx!(%{input_txids: [parent.txid]})
    tx!(%{input_txids: [center.txid]})

    {_graph, queries} = queries(fn -> TxGraph.build(center.txid, 2) end)

    # The start, then at most two levels back and two forward.
    assert length(queries) <= 5
    refute Enum.any?(queries, &(&1 =~ ~s("raw") or &1 =~ ~s("inputs")))
  end

  test "an unknown txid is not found" do
    assert TxGraph.build("nope", 2) == {:error, :not_found}
  end
end
