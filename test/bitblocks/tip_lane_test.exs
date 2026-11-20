defmodule Bitblocks.TipLaneTest do
  @moduledoc """
  A tip lane (#139): one projection's slice of the chain, read at the tip
  ahead of the sync. Blocks are made up in the test (`SyntheticBlock`) and
  served by the stubbed node, so every byte the lane reads is checked
  against its header as the sync checks it.
  """
  use Bitblocks.DataCase, async: false

  use Oban.Testing, repo: Bitblocks.Repo
  import Bitblocks.ChainFixtures

  alias Bitblocks.{Projections, Release, Sync, SyntheticBlock, TipLane}
  alias Bitblocks.Chain.{Block, Spend, Transaction}
  alias Bitblocks.TipLane.{Lane, LaneBlock}
  alias Bitblocks.Workers.FetchTransactionsWorker
  alias BitblocksWeb.RpcStub

  setup do
    RpcStub.setup()
    RpcStub.clear()

    pkh = :crypto.strong_rand_bytes(20)
    address = BSV.Address.to_string(%BSV.Address{pubkey_hash: pkh})

    {:ok, projection} =
      Projections.create(%{
        tenant: "pba",
        name: "election",
        filter: %{"output_addresses" => [address]},
        from_height: 100
      })

    %{pkh: pkh, address: address, projection: projection}
  end

  # A tx paying `pkh`, with a second output to a random key.
  defp pays(pkh, sats \\ 5_000),
    do:
      SyntheticBlock.tx(
        [{:crypto.strong_rand_bytes(32), 0, :crypto.strong_rand_bytes(107)}],
        [{sats, SyntheticBlock.p2pkh(pkh)}, {1_000, random_out()}]
      )

  defp unrelated,
    do:
      SyntheticBlock.tx(
        [{:crypto.strong_rand_bytes(32), 0, :crypto.strong_rand_bytes(107)}],
        [{7_000, random_out()}]
      )

  # A tx spending output `vout` of `parent` (serialized).
  defp spends(parent, vout),
    do:
      SyntheticBlock.tx(
        [{SyntheticBlock.sha256d(parent), vout, :crypto.strong_rand_bytes(107)}],
        [{900, random_out()}]
      )

  defp random_out, do: SyntheticBlock.p2pkh(:crypto.strong_rand_bytes(20))

  defp txid(tx), do: tx |> SyntheticBlock.sha256d() |> SyntheticBlock.display()

  # A header-only block above the sync, served by the node's REST interface.
  defp serve(height, txs) do
    block = SyntheticBlock.from_txs([SyntheticBlock.coinbase() | txs])
    RpcStub.stub_rest_block(block.hash, {:ok, block.bytes})

    block_fixture(%{
      height: height,
      hash: block.hash,
      merkleroot: block.merkleroot,
      num_tx: length(block.txids),
      size: byte_size(block.bytes),
      tx: [],
      sync_state: "header_only"
    })
  end

  defp stored_txids, do: Repo.all(from(t in Transaction, select: t.txid)) |> Enum.sort()

  defp start!(projection, from \\ 100) do
    assert {:ok, %{state: "running"}} =
             Release.start_tip_lane(projection.id, from_height: from, apply: true)
  end

  test "stores only the matching txs and the spends of their outputs", %{
    pkh: pkh,
    projection: projection
  } do
    match = pays(pkh)
    other = unrelated()
    spend_in_block = spends(match, 1)
    b100 = serve(100, [match, other, spend_in_block])

    later_spend = spends(match, 0)
    b101 = serve(101, [unrelated(), later_spend])

    # Dry run: what it would read and keep, and nothing started.
    assert {:ok, plan} = Release.start_tip_lane(projection.id, from_height: 100)
    assert plan.dry_run
    assert plan.blocks_to_read == 2
    assert plan.blocks_streamed == 0
    assert plan.stores =~ "only txs matching"
    assert plan.sync_slots.while_running < plan.sync_slots.limit or plan.sync_slots.limit == 1
    assert TipLane.get(projection.id) == nil

    start!(projection)
    assert [%Oban.Job{}] = all_enqueued(worker: Bitblocks.Workers.TipLaneWorker)

    Phoenix.PubSub.subscribe(Bitblocks.PubSub, TipLane.topic(projection.id))

    assert {:ok, [%{read: 2, kept: 3, stopped: :tip}]} = TipLane.run()
    assert_receive {:tip_lane_block, %{height: 100, hash: hash100}}
    assert hash100 == b100.hash
    assert_receive {:tip_lane_block, %{height: 101}}

    assert stored_txids() == Enum.sort([txid(match), txid(spend_in_block), txid(later_spend)])

    # Through the whole pipeline: the spends are recorded.
    assert Repo.exists?(from(s in Spend, where: s.spending_txid == ^txid(later_spend)))

    # The sync still owns completion.
    assert Repo.get!(Block, b100.id).sync_state == "header_only"
    assert Repo.get!(Block, b101.id).sync_state == "header_only"
    assert Sync.complete_through() == -1

    status = Projections.status(projection)
    assert status.tip_lane_through_height == 101
    assert status.stable_through_height == 101
    assert TipLane.status(projection).behind_blocks == 0
    assert status.tip_lane.waiting_on == nil
    assert status.tip_lane.txs_kept == 3

    # Hydrate and follow serve the lane's blocks as covered.
    assert {:ok, %{txs: [_], complete: true}} = Projections.hydrate(projection)
    assert {:ok, [%Transaction{}]} = Projections.follow_since(projection, 99)
    assert Projections.follow_resume(projection, 99) == 101

    # Caught up: the next run reads nothing.
    fetches = length(RpcStub.calls(:rest_block))
    assert {:ok, [%{read: 0, stopped: :tip}]} = TipLane.run()
    assert length(RpcStub.calls(:rest_block)) == fetches

    # When the full sync reaches the block, it treats the lane's rows as stored.
    assert :ok = FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => b100.hash}})
    assert Repo.get!(Block, b100.id).sync_state == "completed"

    assert Repo.one(from(t in Transaction, where: t.block_hash == ^b100.hash, select: count())) ==
             4
  end

  test "an orphaned block's rows are rewound and the new block read", %{
    pkh: pkh,
    projection: projection
  } do
    match = pays(pkh)
    serve(100, [match])
    orphaned_spend = spends(match, 0)
    old101 = serve(101, [orphaned_spend])

    start!(projection)
    assert {:ok, [%{read: 2, kept: 2}]} = TipLane.run()
    assert txid(orphaned_spend) in stored_txids()

    # Header sync resolves a reorg: block 101 is replaced.
    Repo.delete!(old101)
    new_match = pays(pkh, 6_000)
    new101 = serve(101, [new_match, unrelated()])

    assert TipLane.through(TipLane.get(projection.id)) == 100
    assert Projections.status(projection).tip_lane.waiting_on == "Block 101 is next to read."

    assert {:ok, [%{read: 1, kept: 1, stopped: :tip}]} = TipLane.run()

    assert stored_txids() == Enum.sort([txid(match), txid(new_match)])
    refute Repo.exists?(from(s in Spend, where: s.spending_txid == ^txid(orphaned_spend)))

    assert %LaneBlock{block_hash: hash, status: "read"} =
             Repo.get_by(LaneBlock, projection_id: projection.id, height: 101)

    assert hash == new101.hash
    assert Projections.status(projection).tip_lane_through_height == 101
  end

  test "a lane that falls behind says how far, and catches up from where it stopped", %{
    pkh: pkh,
    projection: projection
  } do
    serve(100, [pays(pkh)])
    start!(projection)

    assert {:ok, [%{read: 1, stopped: :tip}]} = TipLane.run()

    # Two new headers; the node can't serve the first yet.
    b101 = serve(101, [pays(pkh)])
    serve(102, [unrelated()])
    RpcStub.stub_rest_block(b101.hash, {:error, {:http_error, 503}})
    RpcStub.stub_getblock(b101.hash, 0, {:error, :unavailable})

    assert {:ok, [%{read: 0, stopped: {101, _reason}}]} = TipLane.run()

    status = Projections.status(projection)
    assert status.tip_lane_through_height == 100
    assert TipLane.status(projection).behind_blocks == 2
    assert status.tip_lane.waiting_on =~ "Block 101 couldn't be read yet"
    assert status.tip_lane.waiting_on =~ "1 try"

    # Backing off: not asked again within the minute.
    assert {:ok, [%{stopped: {101, {:backing_off, _}}}]} = TipLane.run()

    # Past the backoff, and the node serves it: the lane carries on from 101.
    Repo.update_all(LaneBlock, set: [read_at: ~U[2020-01-01 00:00:00Z]])
    block101 = SyntheticBlock.from_txs([SyntheticBlock.coinbase(), pays(pkh)])

    Repo.update_all(from(b in Block, where: b.height == 101),
      set: [merkleroot: block101.merkleroot, num_tx: 2, hash: block101.hash]
    )

    RpcStub.stub_rest_block(block101.hash, {:ok, block101.bytes})

    assert {:ok, [%{read: 2, stopped: :tip}]} = TipLane.run()
    assert Projections.status(projection).tip_lane_through_height == 102
    assert TipLane.status(projection).behind_blocks == 0
  end

  test "a block over the raw cap streams, and only its slice is kept", %{
    pkh: pkh,
    projection: projection
  } do
    big = SyntheticBlock.build(33 * 1024 * 1024, pay_to: pkh, pay_sats: 70_000)
    RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

    block_fixture(%{
      height: 100,
      hash: big.hash,
      merkleroot: big.merkleroot,
      num_tx: length(big.txids),
      size: byte_size(big.bytes),
      tx: [],
      sync_state: "header_only"
    })

    start!(projection)
    assert {:ok, [%{read: 1, kept: 1, stopped: :tip}]} = TipLane.run()
    assert stored_txids() == [Enum.at(big.txids, 1)]
    assert RpcStub.calls(:rest_block_stream) == [[big.hash]]

    assert %LaneBlock{source: "rest_stream"} =
             Repo.get_by(LaneBlock, projection_id: projection.id, height: 100)
  end

  test "takes one slot of the RPC budget, and stops keeping its rows", %{
    pkh: pkh,
    projection: projection
  } do
    {limit, _} = Sync.concurrency_limit()
    assert TipLane.sync_slots(limit) == limit

    b100 = serve(100, [pays(pkh)])
    start!(projection)
    assert TipLane.sync_slots(limit) == max(limit - 1, 1)

    # A block the sync holds is the sync's to read.
    {:ok, owner} = Oban.insert(FetchTransactionsWorker.new(%{"block_hash" => b100.hash}))
    assert {:ok, [%{read: 0, stopped: {:waiting, {:sync_owns_block, 100}}}]} = TipLane.run()
    Repo.delete!(owner)

    # Every slot of the budget in use: the lane waits for one.
    jobs =
      for i <- 1..limit do
        {:ok, job} = Oban.insert(FetchTransactionsWorker.new(%{"block_hash" => "other_#{i}"}))
        job
      end

    assert {:ok, [%{read: 0, stopped: {:waiting, :rpc_budget}}]} = TipLane.run()
    Enum.each(jobs, &Repo.delete!/1)
    assert RpcStub.calls(:rest_block) == []

    assert {:ok, [%{read: 1}]} = TipLane.run()

    assert {:ok, %{state: "stopped"}} = Release.stop_tip_lane(projection.id)
    assert TipLane.sync_slots(limit) == limit
    assert [_] = stored_txids()

    # A stopped lane reads nothing, and still reports how far it reached.
    serve(101, [pays(pkh)])
    assert {:ok, []} = TipLane.run()

    assert %{tip_lane_through_height: 100, tip_lane: %{state: "stopped"}} =
             Projections.status(projection)

    # Started again, it carries on from where it stopped.
    start!(projection)
    assert {:ok, [%{read: 1}]} = TipLane.run()
    assert %Lane{status: "running"} = TipLane.get(projection.id)
  end

  test "refuses a projection that isn't a tx filter" do
    {:ok, commands} =
      Projections.create(%{tenant: "bitcom", name: "c", source: "bitcom_commands"})

    assert {:error, :not_a_tx_projection} = Release.start_tip_lane(commands.id, from_height: 1)
  end
end
