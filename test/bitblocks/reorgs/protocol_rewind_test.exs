defmodule Bitblocks.Reorgs.ProtocolRewindTest do
  # #52 and #53: a two-block fork at height 900,501. Every protocol row from a
  # transaction only the replaced block held stops counting; a transaction
  # mined in both blocks keeps its rows.
  use Bitblocks.DataCase

  import Bitblocks.ChainFixtures

  import Bitblocks.OrdinalFixtures,
    only: [address: 0, funding_outpoint: 0, p2pkh: 2, publish: 1, tx: 2]

  alias Bitblocks.{OrderBook, OrdinalCollections, ProtocolRegistry, Tokens}
  alias Bitblocks.Chain.{Block, RawBlock, Spend, TxIngest}
  alias Bitblocks.OrdinalCollections.Item
  alias Bitblocks.ProtocolRegistry.Instance
  alias Bitblocks.Reorgs
  alias Bitblocks.Reorgs.Reconcile
  alias Bitblocks.Workers.CollectionTraceWorker
  alias BitblocksWeb.RpcStub

  @height 900_501
  @orphan "orphan_900501"
  @replacement "replacement_900501"
  @tardinians OrdinalCollections.known()["grand-tardinians"]
  @rexxies OrdinalCollections.known()["rexxies"]

  setup do
    # No node stubs: lookups come from the WoC stub, which knows no tx here, so
    # a tx outside the replacement's list is one no block holds.
    RpcStub.setup()
    RpcStub.clear()

    ancestor = block_fixture(%{height: @height - 1, hash: "ancestor_900500", merkleroot: nil})
    orphan = block_fixture(%{height: @height, hash: @orphan, merkleroot: nil})

    %{ancestor: ancestor, orphan: orphan, alice: address(), bob: address()}
  end

  # The fork resolves: the orphan's row goes, as in tip sync, and the block
  # holding `shared` takes its height.
  defp resolve_fork(shared \\ []) do
    Repo.delete_all(from(b in Block, where: b.hash == ^@orphan))

    {:ok, _reorg} =
      Reorgs.record_observed(
        %{fork_height: @height, fork_point: @height - 1, orphan_count: 1, outcome: "resolved"},
        ~U[2026-11-06 00:00:00Z]
      )

    block_fixture(%{
      height: @height,
      hash: @replacement,
      merkleroot: nil,
      num_tx: length(shared),
      tx: shared,
      sync_state: "completed"
    })
  end

  defp reconcile!(opts \\ [apply: true]) do
    {:ok, report} = Reconcile.run(@orphan, Keyword.put(opts, :height, @height))
    report
  end

  defp row(txid), do: Repo.get_by(Instance, txid: txid)

  defp token_out(fields, owner) do
    {:ok, %BSV.Address{pubkey_hash: pkh}} = BSV.Address.from_string(owner)
    body = Jason.encode!(Map.put(fields, "p", "bsv-20"))

    %BSV.TxOut{
      satoshis: 1,
      script: %BSV.Script{
        chunks:
          [:OP_FALSE, :OP_IF, "ord", :OP_1, "application/bsv-20", :OP_0, body, :OP_ENDIF] ++
            [:OP_DUP, :OP_HASH160, pkh, :OP_EQUALVERIFY, :OP_CHECKSIG]
      }
    }
  end

  defp ingest({txid, hex}, block) do
    :ok = TxIngest.store(RawBlock.tx_json(txid, Base.decode16!(hex, case: :lower)), block)
    txid
  end

  defp mint(block, owner) do
    out = token_out(%{"op" => "deploy+mint", "amt" => "1000", "sym" => "T"}, owner)
    txid = ingest(tx([funding_outpoint()], [out]), block)
    "#{txid}_0"
  end

  defp transfer(block, from, token_id, owner) do
    out = token_out(%{"op" => "transfer", "id" => token_id, "amt" => "1000"}, owner)
    ingest(tx([from], [out]), block)
  end

  describe "BSV-21 rows (#52)" do
    test "a dry run reports the rows and changes none", ctx do
      token_id = mint(ctx.ancestor, ctx.alice)
      xfer = transfer(ctx.orphan, token_id, token_id, ctx.bob)
      resolve_fork()

      report = reconcile!(apply: false)

      assert report.plan.protocols.tokens == %{moved: 0, removed: 1, rechecked: 0}
      assert row(xfer)
      assert Tokens.balance_of(token_id, ctx.bob) == 1000
    end

    test "an orphan-only transfer goes, and the balance returns to its holder", ctx do
      token_id = mint(ctx.ancestor, ctx.alice)
      xfer = transfer(ctx.orphan, token_id, token_id, ctx.bob)
      assert Tokens.balance_of(token_id, ctx.bob) == 1000
      assert Tokens.balance_of(token_id, ctx.alice) == 0

      resolve_fork()
      report = reconcile!()

      assert report.result.protocols.tokens.removed == 1
      refute row(xfer)
      assert Tokens.balance_of(token_id, ctx.bob) == 0
      assert Tokens.balance_of(token_id, ctx.alice) == 1000
    end

    test "an orphan-only mint goes, and a transfer spending it stops counting", ctx do
      token_id = mint(ctx.orphan, ctx.alice)
      [mint_txid, _] = String.split(token_id, "_")

      # Its block is another branch's, reconciled in its own turn.
      later = block_fixture(%{height: @height + 1, hash: "later_900502", merkleroot: nil})
      xfer = transfer(later, token_id, token_id, ctx.bob)
      assert row(xfer).state["status"] == "valid"

      resolve_fork()
      report = reconcile!()

      assert report.result.protocols.tokens == %{moved: 0, removed: 1, rechecked: 1}
      refute row(mint_txid)
      assert Tokens.get_token(token_id) == nil
      assert row(xfer).state["status"] == "pending"
      assert Tokens.token_holders(token_id) == []
    end

    test "a transaction mined in both blocks keeps its rows, on the new block", ctx do
      token_id = mint(ctx.ancestor, ctx.alice)
      xfer = transfer(ctx.orphan, token_id, token_id, ctx.bob)
      resolve_fork([xfer])

      report = reconcile!()

      assert report.result.protocols.tokens.moved == 1
      assert %{block_hash: @replacement, block_height: @height} = row(xfer)
      assert row(xfer).state["status"] == "valid"
      assert Tokens.balance_of(token_id, ctx.bob) == 1000
    end

    test "the tx fetch that moves a shared transaction moves its rows too", ctx do
      token_id = mint(ctx.ancestor, ctx.alice)
      xfer = transfer(ctx.orphan, token_id, token_id, ctx.bob)
      replacement = resolve_fork([xfer])

      TxIngest.existing_txids([xfer], replacement)

      assert %{block_hash: @replacement, block_height: @height} = row(xfer)

      # The reconcile finds nothing left to do.
      report = reconcile!()
      assert report.plan.rows == 0
      assert Tokens.balance_of(token_id, ctx.bob) == 1000
    end

    test "running the reconcile again changes nothing", ctx do
      token_id = mint(ctx.ancestor, ctx.alice)
      transfer(ctx.orphan, token_id, token_id, ctx.bob)
      resolve_fork()
      reconcile!()

      assert %{result: %{removed: 0, protocols: %{tokens: %{removed: 0}}}} = reconcile!()
      assert Tokens.balance_of(token_id, ctx.alice) == 1000
    end
  end

  describe "classic BSV-20 rows (#52)" do
    defp deploy(block) do
      out = token_out(%{"op" => "deploy", "tick" => "TEST", "max" => "21000"}, address())
      ingest(tx([funding_outpoint()], [out]), block)
    end

    test "an orphan-only deploy goes", ctx do
      txid = deploy(ctx.orphan)
      assert row(txid)

      resolve_fork()
      reconcile!()

      refute row(txid)
    end

    test "a deploy mined in both blocks stays, on the new block", ctx do
      txid = deploy(ctx.orphan)
      resolve_fork([txid])
      reconcile!()

      assert %{block_hash: @replacement} = row(txid)
    end
  end

  describe "listings (#52)" do
    setup do
      ProtocolRegistry.get_protocol_by_name("OrderBook") ||
        raise "OrderBook protocol not seeded — run mix ecto.migrate"

      :ok
    end

    defp listing(txid, hash) do
      transaction_fixture(%{txid: txid, block_hash: hash, block_height: @height})

      {:ok, _listing} =
        OrderBook.index_listing(%{
          txid: txid,
          vout: 0,
          block_height: @height,
          block_hash: hash,
          parsed_data: %{
            "op" => "list",
            "token_id" => "tok_0",
            "quantity" => "100",
            "price_satoshis" => "5000",
            "seller_address" => "seller",
            "token_utxo" => "token_tx:0"
          }
        })

      row(txid)
    end

    defp settled_by(txid, hash) do
      transaction_fixture(%{txid: txid, block_hash: hash, block_height: @height})
      Repo.insert!(%Spend{txid: "token_tx", vout: 0, spending_txid: txid, spending_vin: 0})
      OrderBook.settle_spent_token_utxos([%{txid: "token_tx", vout: 0, spending_txid: txid}])
    end

    test "an orphan-only listing goes" do
      listing("list_gone", @orphan)
      resolve_fork()

      report = reconcile!()

      assert report.result.protocols.listings.removed == 1
      assert OrderBook.get_listing("list_gone") == nil
    end

    test "a listing mined in both blocks stays, on the new block" do
      listing("list_both", @orphan)
      resolve_fork(["list_both"])

      report = reconcile!()

      assert report.result.protocols.listings.moved == 1
      assert %{block_hash: @replacement, spent: false} = row("list_both")
    end

    test "a fill only the replaced block held is undone", ctx do
      listing("list_old", ctx.ancestor.hash)
      settled_by("fill_gone", @orphan)
      assert %{spent: true, state: %{"status" => "filled"}} = row("list_old")

      resolve_fork()
      assert reconcile!(apply: false).plan.protocols.listings.reopened == 1
      assert row("list_old").spent

      report = reconcile!()

      assert report.result.protocols.listings.reopened == 1
      assert %{spent: false, spent_txid: nil, state: state} = row("list_old")
      assert state["status"] == "active"
      assert state["quantity_remaining"] == "100"
      assert state["fills"] == []
    end

    test "when the new block spends the outpoint instead, that spend fills the listing", ctx do
      listing("list_old", ctx.ancestor.hash)
      settled_by("fill_gone", @orphan)
      replacement = resolve_fork(["fill_real"])

      transaction_fixture(%{
        txid: "fill_real",
        block_hash: replacement.hash,
        block_height: @height
      })

      # The real chain's spender takes the spend row, as `Chain.record_spends/1` does.
      Repo.update_all(
        from(s in Spend, where: s.txid == "token_tx"),
        set: [spending_txid: "fill_real"]
      )

      reconcile!()

      assert %{spent: true, spent_txid: "fill_real", state: state} = row("list_old")
      assert state["status"] == "filled"
      assert [%{"txid" => "fill_real", "quantity" => "100"}] = state["fills"]
    end

    test "a fill mined in both blocks stands", ctx do
      listing("list_old", ctx.ancestor.hash)
      settled_by("fill_both", @orphan)
      resolve_fork(["fill_both"])

      reconcile!()

      assert %{spent: true, spent_txid: "fill_both"} = row("list_old")
    end

    test "a cancel only the replaced block held is undone", ctx do
      listing("list_old", ctx.ancestor.hash)
      transaction_fixture(%{txid: "cancel_gone", block_hash: @orphan, block_height: @height})
      {:ok, _} = OrderBook.cancel_listing("list_old", "cancel_gone")
      resolve_fork()

      reconcile!()

      assert %{spent: false, state: %{"status" => "active"}} = row("list_old")
    end

    test "undoing one of two partial fills keeps the other", ctx do
      listing("list_old", ctx.ancestor.hash)
      transaction_fixture(%{txid: "part_gone", block_hash: @orphan, block_height: @height})
      {:ok, _} = OrderBook.fill_listing("list_old", "part_kept", "30")
      {:ok, _} = OrderBook.fill_listing("list_old", "part_gone", "20")
      resolve_fork()

      reconcile!()

      assert %{spent: false, state: state} = row("list_old")
      assert state["status"] == "partially_filled"
      assert state["quantity_remaining"] == "70"
      assert [%{"txid" => "part_kept"}] = state["fills"]
    end
  end

  # An item settled at the end of `trail`.
  defp item(cid, origin_txid, trail, overrides \\ %{}) do
    current = List.last(trail) || origin_txid

    Repo.insert!(
      struct(
        %Item{
          collection_id: cid,
          origin: "#{origin_txid}_0",
          mint_txid: origin_txid,
          mint_height: @height - 1,
          current_outpoint: "#{current}_0",
          owner: "1Owner",
          trace_state: "current",
          trace_source: "whatsonchain",
          traced_at: ~U[2026-11-01 00:00:00Z],
          trail: trail
        },
        overrides
      )
    )
  end

  defp tx_in_orphan(txid),
    do: transaction_fixture(%{txid: txid, block_hash: @orphan, block_height: @height})

  defp reload(item), do: Repo.get(Item, item.id)

  defp assert_marked(item, origin) do
    assert %{
             trace_state: "untraced",
             current_outpoint: ^origin,
             owner: nil,
             trail: [],
             traced_at: nil
           } = reload(item)
  end

  defp assert_settled(item, outpoint, trail) do
    assert %{trace_state: "current", current_outpoint: ^outpoint, owner: "1Owner", trail: ^trail} =
             reload(item)
  end

  defp trace_jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "Bitblocks.Workers.CollectionTraceWorker"))
  end

  describe "RUN items (#53)" do
    test "a dry run counts the items and marks none" do
      tx_in_orphan("hop_gone")
      crossing = item(@rexxies, "mint_a", ["hop_gone"])
      resolve_fork()

      assert reconcile!(apply: false).plan.protocols.collection_items.retrace == 1
      assert_settled(crossing, "hop_gone_0", ["hop_gone"])
      assert trace_jobs() == []
    end

    test "a trail through a replaced block is marked; one with no hop there keeps its state" do
      tx_in_orphan("hop_gone")
      crossing = item(@rexxies, "mint_a", ["hop_safe", "hop_gone", "hop_after"])
      safe = item(@rexxies, "mint_b", ["hop_safe"])
      ended = item(@rexxies, "mint_c", ["hop_safe"], %{trace_state: "ended", owner: nil})
      resolve_fork()

      report = reconcile!()

      assert report.result.protocols.collection_items.retrace == 1
      assert_marked(crossing, "mint_a_0")
      assert_settled(safe, "hop_safe_0", ["hop_safe"])
      assert %{trace_state: "ended", trail: ["hop_safe"]} = reload(ended)
    end

    test "a hop mined in both blocks is marked too: RUN redoes any trail through the block" do
      tx_in_orphan("hop_both")
      crossing = item(@rexxies, "mint_a", ["hop_both"])
      safe = item(@rexxies, "mint_b", [])
      resolve_fork(["hop_both"])

      reconcile!()

      assert_marked(crossing, "mint_a_0")
      assert_settled(safe, "mint_b_0", [])
    end

    test "the tx fetch that moves a hop marks the item, before the reconcile runs" do
      tx_in_orphan("hop_both")
      crossing = item(@rexxies, "mint_a", ["hop_both"])
      replacement = resolve_fork(["hop_both"])

      TxIngest.existing_txids(["hop_both"], replacement)

      assert_marked(crossing, "mint_a_0")
      assert [%{args: %{"ids" => [id]}}] = trace_jobs()
      assert id == crossing.id
    end

    test "an item sitting in the block is marked, trail or not" do
      tx_in_orphan("hopgone")
      crossing = item(@rexxies, "mint_a", [], %{current_outpoint: "hopgone_0"})
      resolve_fork()

      reconcile!()

      assert_marked(crossing, "mint_a_0")
    end

    test "an item minted only in the replaced block goes" do
      tx_in_orphan("mint_gone")
      minted = item(@rexxies, "mint_gone", [])
      resolve_fork()

      report = reconcile!()

      assert report.result.protocols.collection_items.removed == 1
      refute reload(minted)
    end

    test "marked items queue a re-trace, and a second run queues nothing" do
      tx_in_orphan("hop_gone")
      crossing = item(@rexxies, "mint_a", ["hop_gone"])
      resolve_fork()

      reconcile!()

      assert [%{queue: "collections", args: args}] = trace_jobs()
      assert %{"slug" => @rexxies, "ids" => [id]} = args
      assert id == crossing.id

      reconcile!()
      assert length(trace_jobs()) == 1
    end
  end

  describe "1Sat items (#52)" do
    test "a trail through an orphan-only tx is marked, and says why" do
      tx_in_orphan("hop_gone")
      crossing = item(@tardinians, "mint_a", ["hop_gone"])
      safe = item(@tardinians, "mint_b", ["hop_elsewhere"])
      resolve_fork()

      reconcile!()

      assert_marked(crossing, "mint_a_0")
      assert_settled(safe, "hop_elsewhere_0", ["hop_elsewhere"])
      assert OrdinalCollections.ownership_sentence(reload(crossing)) =~ "reorg"
    end

    test "a hop mined in both blocks keeps the item's answer" do
      tx_in_orphan("hop_both")
      moved = item(@tardinians, "mint_a", ["hop_both"])
      resolve_fork(["hop_both"])

      reconcile!()

      assert_settled(moved, "hop_both_0", ["hop_both"])
      assert trace_jobs() == []
    end

    test "an item minted only in the replaced block goes" do
      tx_in_orphan("mint_gone")
      minted = item(@tardinians, "mint_gone", [])
      resolve_fork()

      reconcile!()

      refute reload(minted)
    end

    test "a mint re-mined in a later block keeps the item, at its new height" do
      tx_in_orphan("mint_both")
      minted = item(@tardinians, "mint_both", [], %{mint_height: @height})
      resolve_fork()
      block_fixture(%{height: @height + 1, hash: "later_900502", merkleroot: nil})

      Process.put(:woc_txs, %{
        "mint_both" => %{
          "txid" => "mint_both",
          "blockhash" => "later_900502",
          "blockheight" => @height + 1
        }
      })

      reconcile!()

      assert %{mint_height: 900_502, trace_state: "current"} = reload(minted)
    end

    test "the queued re-trace puts the item back at its canonical owner" do
      owner = address()
      origin_txid = tx([funding_outpoint()], [p2pkh(owner, 1)]) |> publish()
      OrdinalCollections.import_txs([origin_txid])

      tx_in_orphan("hop_gone")
      crossing = item(@tardinians, origin_txid, ["hop_gone"])
      resolve_fork()

      reconcile!()
      assert [job] = trace_jobs()

      assert :ok = CollectionTraceWorker.perform(job)

      origin = "#{origin_txid}_0"

      assert %{trace_state: "current", current_outpoint: ^origin, owner: ^owner, trail: []} =
               reload(crossing)
    end
  end

  describe "the trace race (#73)" do
    test "a trace that read the item before a reorg marked it doesn't overwrite the mark" do
      owner = address()
      origin_txid = tx([funding_outpoint()], [p2pkh(owner, 1)]) |> publish()
      OrdinalCollections.import_txs([origin_txid])
      origin = "#{origin_txid}_0"

      # What a running trace read: settled, its trail through a tx the reorg removes.
      read =
        item(@tardinians, origin_txid, ["hop_gone"], %{current_outpoint: origin})

      # The reorg marks the item while that trace walks.
      assert %{retrace: 1} = OrdinalCollections.rewind_removed(["hop_gone"])

      # The trace finishes with an answer from its stale read; the mark stands.
      assert {:ok, %{trace_state: "untraced", trail: []}} = OrdinalCollections.trace(read)
      assert_marked(read, origin)

      # The re-trace the mark queued answers from the row as it now is.
      assert {:ok, %{trace_state: "current", owner: ^owner, trail: []}} =
               OrdinalCollections.trace(reload(read))
    end

    test "a trace of an item the reorg removed says so" do
      read = item(@tardinians, "mintgone", [])
      OrdinalCollections.rewind_removed(["mintgone"])

      assert {:error, :gone} = OrdinalCollections.trace(read)
    end
  end

  describe "partial fills (#73)" do
    test "undoing an earlier partial fill leaves a listing a kept tx filled filled, nothing remaining",
         ctx do
      listing("list_old", ctx.ancestor.hash)
      transaction_fixture(%{txid: "part_gone", block_hash: @orphan, block_height: @height})
      {:ok, _} = OrderBook.fill_listing("list_old", "part_gone", "30")
      settled_by("fill_kept", ctx.ancestor.hash)
      assert %{spent: true, state: %{"quantity_remaining" => "0"}} = row("list_old")

      resolve_fork()
      reconcile!()

      assert %{spent: true, spent_txid: "fill_kept", state: state} = row("list_old")
      assert state["status"] == "filled"
      assert state["quantity_remaining"] == "0"
      assert [%{"txid" => "fill_kept", "quantity" => "100"}] = state["fills"]
    end
  end

  describe "earlier reorgs: the sweep (#73)" do
    alias Bitblocks.Reorgs.Sweep

    # A reconcile from before the rewinds: the tx rows and spend edges went,
    # the protocol rows stayed under the orphan's hash.
    defp old_reconcile_removed(txid) do
      Repo.delete_all(from(s in Spend, where: s.spending_txid == ^txid))
      Repo.delete_all(from(t in Bitblocks.Chain.Transaction, where: t.txid == ^txid))
    end

    test "a dry run finds the rows and changes none; apply removes them", ctx do
      token_id = mint(ctx.ancestor, ctx.alice)
      xfer = transfer(ctx.orphan, token_id, token_id, ctx.bob)
      crossing = item(@tardinians, "mint_a", [xfer])
      resolve_fork()
      old_reconcile_removed(xfer)

      assert {:ok, %{applied: false, plan: plan}} = Sweep.run()
      assert plan.rows == 1
      assert [{@orphan, @height, 1}] = plan.orphans
      assert plan.removed == [xfer]
      assert plan.protocols.tokens.removed == 1
      assert plan.protocols.collection_items.retrace == 1
      assert row(xfer)
      assert Tokens.balance_of(token_id, ctx.bob) == 1000

      assert {:ok, %{applied: true, result: result}} = Sweep.run(apply: true)
      assert result.tokens.removed == 1
      refute row(xfer)
      assert Tokens.balance_of(token_id, ctx.alice) == 1000
      assert_marked(crossing, "mint_a_0")

      assert {:ok, %{plan: %{rows: 0}}} = Sweep.run()
    end

    test "a row whose tx sits in a stored block now moves with it" do
      transaction_fixture(%{txid: "list_both", block_hash: @orphan, block_height: @height})

      {:ok, _} =
        OrderBook.index_listing(%{
          txid: "list_both",
          vout: 0,
          block_height: @height,
          block_hash: @orphan,
          parsed_data: %{"op" => "list", "token_id" => "t", "quantity" => "1"}
        })

      replacement = resolve_fork(["list_both"])

      Repo.update_all(from(t in Bitblocks.Chain.Transaction, where: t.txid == "list_both"),
        set: [block_hash: replacement.hash]
      )

      assert {:ok, %{plan: %{moved: [{@replacement, @height, ["list_both"]}]}}} =
               Sweep.run(apply: true)

      assert %{block_hash: @replacement} = row("list_both")
    end

    test "a row whose tx still carries the orphan's hash waits for its reconcile", ctx do
      token_id = mint(ctx.ancestor, ctx.alice)
      xfer = transfer(ctx.orphan, token_id, token_id, ctx.bob)
      resolve_fork()

      assert {:ok, %{plan: plan}} = Sweep.run(apply: true)
      assert plan.unreconciled == [{@orphan, [xfer]}]
      assert plan.removed == []
      assert row(xfer)
    end

    test "a removed tx whose block isn't complete yet is left for a later run", ctx do
      token_id = mint(ctx.ancestor, ctx.alice)
      xfer = transfer(ctx.orphan, token_id, token_id, ctx.bob)
      replacement = resolve_fork()

      Repo.update_all(from(b in Block, where: b.id == ^replacement.id),
        set: [sync_state: "header_only"]
      )

      old_reconcile_removed(xfer)

      assert {:ok, %{plan: %{pending: [^xfer], removed: []}}} = Sweep.run(apply: true)
      assert row(xfer)
    end

    test "an item with a hop not in our index is reported, not marked" do
      crossing = item(@tardinians, "mint_unknown", ["hop_unknown"])

      assert {:ok, %{plan: plan}} = Sweep.run(apply: true)
      assert {crossing.id, ["mint_unknown", "hop_unknown"]} in plan.unindexed_hops
      assert_settled(crossing, "hop_unknown_0", ["hop_unknown"])
    end
  end
end
