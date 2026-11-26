defmodule Bitblocks.Chain.TxGraphTest do
  # The graph around a tx, walked level by level on indexes: it never reads
  # `raw` or `inputs`, and costs one query a level each way.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  import Ecto.Query

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{Transaction, TxGraph}

  # A tx as the pipeline stores it: `input_txids` from its inputs, and a
  # `spend_index` row per input (`record_spends`), which the forward walk reads.
  defp tx!(attrs \\ %{})

  defp tx!(%{input_txids: [_ | _] = parents} = attrs) do
    inputs =
      for parent <- parents,
          do: Jason.encode!(%{txid: parent, vout: System.unique_integer([:positive])})

    tx = attrs |> Map.put(:inputs, inputs) |> transaction_fixture()
    Chain.record_spends(tx)
    tx
  end

  defp tx!(attrs), do: transaction_fixture(attrs)

  # The forward lookup the walk made before it moved onto spend_index: rows
  # whose `input_txids` (GIN) overlap the frontier.
  defp children_by_input_txids(frontier) do
    from(t in Transaction,
      where: fragment("? && ?::varchar[]", t.input_txids, ^frontier),
      select: {t.txid, t.input_txids}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {child, input_txids} ->
      for parent <- input_txids, parent in frontier, do: {parent, child}
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

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

  test "a row with no input_txids still shows its parents, and spend_index its spenders" do
    parent = tx!()
    input = Jason.encode!(%{txid: parent.txid, vout: 0})
    center = tx!(%{inputs: [input], input_txids: nil})
    spender = tx!(%{input_txids: nil})

    Repo.insert!(%Bitblocks.Chain.Spend{
      txid: center.txid,
      vout: 0,
      spending_txid: spender.txid,
      spending_vin: 0
    })

    graph = TxGraph.build(center.txid, 1)

    assert levels(graph) == %{parent.txid => -1, center.txid => 0, spender.txid => 1}
    assert edges(graph) == Enum.sort([{parent.txid, center.txid}, {center.txid, spender.txid}])
  end

  test "a spender found both ways is one edge" do
    center = tx!()
    spender = tx!(%{input_txids: [center.txid]})

    Repo.insert!(%Bitblocks.Chain.Spend{
      txid: center.txid,
      vout: 0,
      spending_txid: spender.txid,
      spending_vin: 0
    })

    assert [_] = TxGraph.build(center.txid, 1).edges
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

  test "reads no raw, reads inputs only for rows without input_txids, and stays bounded" do
    grandparent = tx!()
    parent = tx!(%{input_txids: [grandparent.txid]})
    center = tx!(%{input_txids: [parent.txid]})
    tx!(%{input_txids: [center.txid]})

    {_graph, queries} = queries(fn -> TxGraph.build(center.txid, 2) end)

    # The start, two levels back, and two forward.
    assert length(queries) <= 5
    refute Enum.any?(queries, &(&1 =~ ~s("raw") or &1 =~ ~s("inputs")))
  end

  test "the forward walk never asks the input_txids GIN index" do
    center = tx!()
    tx!(%{input_txids: [center.txid]})

    {_graph, queries} = queries(fn -> TxGraph.build(center.txid, 2) end)

    refute Enum.any?(queries, &(&1 =~ ~r/"input_txids"\s*(&&|@>)/)), Enum.join(queries, "\n")
    assert Enum.any?(queries, &(&1 =~ ~s("spend_index")))
  end

  test "finds the same spenders the input_txids lookup found" do
    a = tx!()
    b = tx!()
    # One child of a, one of both, one of b twice, and a grandchild.
    c1 = tx!(%{input_txids: [a.txid]})
    c2 = tx!(%{input_txids: [a.txid, b.txid]})
    c3 = tx!(%{input_txids: [b.txid, b.txid]})
    g = tx!(%{input_txids: [c1.txid, c3.txid]})
    tx!()

    for start <- [a, b, c1, c2, c3, g] do
      graph = TxGraph.build(start.txid, 1)
      forward = for e <- graph.edges, e.from == start.txid, do: {e.from, e.to}

      assert Enum.sort(forward) == children_by_input_txids([start.txid]), start.txid
    end

    assert children_by_input_txids([a.txid, b.txid]) ==
             Enum.sort([
               {a.txid, c1.txid},
               {a.txid, c2.txid},
               {b.txid, c2.txid},
               {b.txid, c3.txid}
             ])
  end

  test "an unknown txid is not found" do
    assert TxGraph.build("nope", 2) == {:error, :not_found}
  end
end
