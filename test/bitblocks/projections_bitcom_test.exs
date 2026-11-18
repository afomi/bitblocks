defmodule Bitblocks.ProjectionsBitcomTest do
  @moduledoc """
  #29 Tenant 3: the Bitcom registry's command log (`bitcom_commands`) served
  through the managed projection API, with hydrate's guarantees. See
  docs/MANAGED_SERVICES.md, "Design: a projection source".
  """
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.Bitcom.Command
  alias Bitblocks.Projections
  alias Bitblocks.Projections.Projection
  alias Bitblocks.Reorgs.ProtocolRewind

  @actor "1BitcomActorXXXXXXXXXXXXXXXXXXXXX"

  defp bitcom_projection(attrs \\ %{}) do
    {:ok, p} =
      %{tenant: "bitcom", name: "commands", source: "bitcom_commands"}
      |> Map.merge(attrs)
      |> Projections.create()

    p
  end

  # A command in a stored tx under the stored block at `height`.
  defp command(height, n, output_index \\ 0, opts \\ []) do
    txid = String.duplicate(n, 64)
    hash = Keyword.get(opts, :block_hash, "block_#{height}")

    if Keyword.get(opts, :tx, true) and
         is_nil(Repo.get_by(Bitblocks.Chain.Transaction, txid: txid)),
       do: transaction_fixture(%{block_height: height, block_hash: hash, txid: txid})

    Repo.insert!(%Command{
      txid: txid,
      output_index: output_index,
      block_height: height,
      actor: @actor,
      namespace: @actor,
      command: "echo",
      args: ["hello #{n}", "to", "readme"],
      content: "hello #{n}",
      file: "readme",
      valid: true
    })
  end

  defp blocks(range, state \\ "completed") do
    for h <- range, do: block_fixture(%{height: h, hash: "block_#{h}", sync_state: state})
  end

  defp keys(commands), do: Enum.map(commands, &{&1.block_height, &1.txid, &1.output_index})

  defp page_through(p, opts, acc \\ []) do
    {:ok, page} = Projections.hydrate(p, opts)
    acc = acc ++ keys(page.commands)

    case page.next_cursor do
      nil -> acc
      cursor -> page_through(p, Keyword.put(opts, :cursor, cursor), acc)
    end
  end

  describe "create/1 with the bitcom_commands source" do
    test "needs no filter, and its hash names the source" do
      p = bitcom_projection()

      assert p.source == "bitcom_commands"
      assert p.filter == %{}
      assert p.definition_hash == Projection.definition_hash(%{}, "bitcom_commands")

      assert p.definition_hash ==
               :crypto.hash(:sha256, ~s({"filter":[],"source":"bitcom_commands"}))
               |> Base.encode16(case: :lower)
    end

    test "leaves the hash of a tx projection as it was" do
      filter = %{"protocols" => ["MAP"]}
      {:ok, p} = Projections.create(%{tenant: "t", name: "n", filter: filter})

      assert p.source == "transactions"

      assert p.definition_hash ==
               :crypto.hash(:sha256, Jason.encode!([["protocols", ["MAP"]]]))
               |> Base.encode16(case: :lower)
    end

    test "rejects a filter, an unknown source and a webhook" do
      base = %{tenant: "t", name: "n", source: "bitcom_commands"}

      assert {:error, cs} = Projections.create(Map.put(base, :filter, %{"protocols" => ["x"]}))
      assert %{filter: [_]} = errors_on(cs)

      assert {:error, cs} = Projections.create(%{base | source: "blocks"})
      assert %{source: [_]} = errors_on(cs)

      assert {:error, cs} =
               Projections.create(Map.put(base, :webhook_url, "https://93.184.216.34/hook"))

      assert %{webhook_url: ["is not offered for the bitcom_commands source"]} = errors_on(cs)
    end
  end

  test "set_webhook is refused on a command projection, and nothing is stored" do
    p = bitcom_projection()

    assert {:error, cs} = Projections.set_webhook(p, "https://93.184.216.34/hook")
    assert %{webhook_url: ["is not offered for the bitcom_commands source"]} = errors_on(cs)

    assert %{webhook_url: nil, webhook_secret: nil} = Projections.get!(p.id)
  end

  describe "hydrate/2" do
    setup do
      blocks([10, 20, 30])
      p = bitcom_projection()

      # Out of order, with two commands in one tx, so ties break on txid and
      # then output_index.
      commands =
        for {height, n, index} <- [
              {30, "1", 0},
              {10, "2", 1},
              {20, "3", 0},
              {10, "2", 0},
              {10, "4", 0}
            ] do
          command(height, n, index)
        end

      %{projection: p, commands: commands}
    end

    test "paging the whole set equals the unpaged, ordered set", %{
      projection: p,
      commands: commands
    } do
      expected = commands |> keys() |> Enum.sort()

      assert {:ok, %{commands: all, next_cursor: nil}} =
               Projections.hydrate(p, snapshot_height: 30)

      assert keys(all) == expected

      for limit <- [1, 2, 3, 5] do
        assert page_through(p, snapshot_height: 30, limit: limit) == expected, "limit #{limit}"
      end
    end

    test "each command carries its block's hash and the logged fields", %{projection: p} do
      {:ok, %{commands: [first | _]}} = Projections.hydrate(p, snapshot_height: 30)

      assert first.block_hash == "block_10"
      assert first.command == "echo"
      assert first.namespace == @actor
    end

    test "a new block doesn't shift pages already handed out", %{projection: p} do
      {:ok, first} = Projections.hydrate(p, snapshot_height: 30, limit: 2)

      blocks([31])
      command(31, "5")
      # And one that sorts before the cursor, at a height already paged.
      command(10, "0")

      {:ok, second} = Projections.hydrate(p, cursor: first.next_cursor, limit: 10)

      assert second.snapshot_height == 30
      assert Enum.map(second.commands, & &1.block_height) == [10, 20, 30]
      refute Enum.any?(second.commands, &(&1.block_height == 31))
    end

    test "serves only commands whose tx stands on the stored chain", %{projection: p} do
      # Logged by discovery with WhatsOnChain's height: no tx row yet.
      command(20, "6", 0, tx: false)
      # Its tx sits under a block we don't hold at that height (an orphan).
      command(20, "7", 0, block_hash: "orphaned_20")
      # Unconfirmed.
      Repo.insert!(%Command{txid: String.duplicate("8", 64), output_index: 0, command: "echo"})

      {:ok, %{commands: commands}} = Projections.hydrate(p, snapshot_height: 30)

      assert length(commands) == 5

      refute Enum.any?(
               commands,
               &(&1.txid in [String.duplicate("6", 64), String.duplicate("7", 64)])
             )
    end

    test "excludes anything above the snapshot, and starts at from_height" do
      blocks([40])
      command(40, "9")

      p = bitcom_projection(%{name: "from-20", from_height: 20})
      {:ok, page} = Projections.hydrate(p, snapshot_height: 30)

      assert Enum.map(page.commands, & &1.block_height) == [20, 30]
    end

    test "rejects a tx projection's cursor and a malformed one", %{projection: p} do
      {:ok, txp} = Projections.create(%{tenant: "x", name: "x", filter: %{"protocols" => ["x"]}})
      foreign = [txp.id, 30, 10, String.duplicate("2", 64)] |> Jason.encode!()
      ours_short = [p.id, 30, 10, String.duplicate("2", 64)] |> Jason.encode!()

      for cursor <- [
            "nope",
            Base.url_encode64(foreign, padding: false),
            Base.url_encode64(ours_short, padding: false)
          ] do
        assert {:error, :invalid_cursor} = Projections.hydrate(p, cursor: cursor)
      end
    end

    test "reads bitcom_commands by its order index, and transactions only by txid", %{
      projection: p
    } do
      Repo.query!("SET LOCAL enable_seqscan = off")

      query = Projections.page_query(p, 30, {10, String.duplicate("2", 64), 0}, 101)
      {sql, params} = Repo.to_sql(:all, query)
      plan = Repo.query!("EXPLAIN " <> sql, params).rows |> Enum.map_join("\n", &hd/1)

      assert plan =~ "bitcom_commands_block_height_txid_output_index_index", plan
      refute plan =~ "Seq Scan on transactions", plan
      refute plan =~ "Seq Scan on bitcom_commands", plan
    end
  end

  describe "status and completeness" do
    test "backfilling while a block in range isn't completed; hydrate says incomplete" do
      blocks(100..102)
      blocks(103..103, "txs_syncing")
      blocks(104..105)
      command(101, "1")
      command(104, "2")

      p = bitcom_projection(%{from_height: 100})

      assert %{index_state: "backfilling", stable_through_height: 102, lag_blocks: 3} =
               Projections.status(p)

      assert {:ok, %{complete: false, stable_through_height: 102, commands: commands}} =
               Projections.hydrate(p)

      assert Enum.map(commands, & &1.block_height) == [101, 104]

      # The first page lies within the stable prefix: that page is final.
      assert {:ok, %{complete: true, commands: [%{block_height: 101}]}} =
               Projections.hydrate(p, limit: 1)
    end

    test "ready once every block from from_height is completed" do
      blocks(100..102)
      p = bitcom_projection(%{from_height: 100})

      assert %{index_state: "ready", stable_through_height: 102} = Projections.status(p)
    end
  end

  describe "follow" do
    setup do
      blocks(10..12)
      command(11, "1")
      command(12, "2", 0)
      command(12, "2", 1)
      %{projection: bitcom_projection()}
    end

    test "follow_since catches up above the position, in order", %{projection: p} do
      assert {:ok, rows} = Projections.follow_since(p, 10)

      assert keys(rows) == [
               {11, String.duplicate("1", 64), 0},
               {12, String.duplicate("2", 64), 0},
               {12, String.duplicate("2", 64), 1}
             ]

      assert Enum.all?(rows, &is_binary(&1.block_hash))
    end

    test "block_matches reads one completed block, and none while it isn't", %{projection: p} do
      assert [%{block_height: 12}, %{block_height: 12}] = Projections.block_matches(p, "block_12")

      block_fixture(%{height: 13, hash: "block_13", sync_state: "txs_syncing"})
      command(13, "3")

      assert [] = Projections.block_matches(p, "block_13")
    end
  end

  describe "reorgs" do
    test "a tx moved to another block carries its commands' height with it" do
      blocks([10, 11])
      p = bitcom_projection()
      command(10, "1")
      txid = String.duplicate("1", 64)

      # The reorg path: the tx row is repointed, then the protocols rewound.
      Repo.update_all(
        from(t in Bitblocks.Chain.Transaction, where: t.txid == ^txid),
        set: [block_hash: "block_11", block_height: 11]
      )

      assert %{bitcom_commands: %{moved: 1}} = ProtocolRewind.plan([txid], [])
      assert %{bitcom_commands: %{moved: 1}} = ProtocolRewind.moved([txid], "block_11", 11)

      assert {:ok, %{commands: [%{block_height: 11, block_hash: "block_11"}]}} =
               Projections.hydrate(p, snapshot_height: 11)
    end

    test "a tx placed after it was stored without a block brings its commands along" do
      blocks([10])
      p = bitcom_projection()
      txid = String.duplicate("a", 64)
      heightless_transaction_fixture(%{txid: txid})
      Repo.insert!(%Command{txid: txid, output_index: 0, command: "echo", actor: @actor})

      assert {:ok, %{commands: []}} = Projections.hydrate(p, snapshot_height: 10)

      Repo.update_all(
        from(t in Bitblocks.Chain.Transaction, where: t.txid == ^txid),
        set: [block_hash: "block_10", block_height: 10]
      )

      ProtocolRewind.moved([txid], "block_10", 10)

      assert {:ok, %{commands: [%{block_height: 10}]}} =
               Projections.hydrate(p, snapshot_height: 10)
    end
  end
end
