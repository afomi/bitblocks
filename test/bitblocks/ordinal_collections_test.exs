defmodule Bitblocks.OrdinalCollectionsTest do
  @moduledoc """
  #30: 1Sat collections. Membership is proven by the mint-contract chain, not
  claimed by MAP; ownership follows the item's sat through spends.
  """
  use Bitblocks.DataCase, async: false

  import Bitblocks.OrdinalFixtures

  alias Bitblocks.OrdinalCollections
  alias Bitblocks.OrdinalCollections.Item
  alias Bitblocks.Ordinals.Inscription

  # A collection whose origin output 0 is the start of the mint chain, and two
  # mints: each spends the previous chain link and carries it on at output 0.
  # Our index is complete through its tip (block 120), and WhatsOnChain may
  # only be asked for raw txs: any other endpoint raises (docs/WOC_USE.md).
  setup do
    Process.put(:woc_raw_tx_only, true)
    index_through(120)

    collection_txid = tx([funding_outpoint()], [contract("collection")]) |> publish(115)
    cid = "#{collection_txid}_0"
    minter = address()

    mint1 = tx([cid], [contract(), item(cid, "Tardinian 1", minter)]) |> publish(116)
    mint2 = tx(["#{mint1}_0"], [contract(), item(cid, "Tardinian 2", minter)]) |> publish(117)

    %{cid: cid, minter: minter, mint1: mint1, mint2: mint2}
  end

  describe "Inscription.parse/1" do
    test "reads content type, parent, MAP and the owner after the envelope", ctx do
      %BSV.TxOut{script: script} = item(ctx.cid, "Tardinian 9", ctx.minter)

      assert {:ok, insc} = Inscription.parse(script)
      assert insc.content_type == "image/svg+xml"
      assert insc.parent == ctx.cid
      assert insc.owner == ctx.minter
      assert insc.map["name"] == "Tardinian 9"
      assert insc.map["subTypeData"]["collectionId"] == ctx.cid
    end

    test "a script without an envelope isn't an inscription" do
      assert {:error, :no_inscription} = Inscription.parse(contract().script)
    end
  end

  describe "sync/3" do
    test "proves members along the chain, follows past the hint, rejects fakes", ctx do
      # Claims the collection in its MAP but doesn't spend the chain.
      fake = tx([funding_outpoint()], [contract(), item(ctx.cid, "Fake", address())]) |> publish()

      # The hint lists mint 1 and the fake; mint 2 is found by following the
      # chain link mint 1 left at output 0.
      spend("#{ctx.mint1}_0", ctx.mint2, 0)

      assert %{mints: 2, items: 2, rejected: 1} =
               OrdinalCollections.sync(ctx.cid, [ctx.mint1, fake])

      items = Repo.all(from i in Item, order_by: i.mint_height)
      assert Enum.map(items, & &1.name) == ["Tardinian 1", "Tardinian 2"]
      assert hd(items).origin == "#{ctx.mint1}_1"
      assert hd(items).owner == ctx.minter

      assert hd(items).traits == [
               %{"name" => "Eyes", "value" => "Reptilian", "description" => "Reptilian!"}
             ]
    end

    test "with follow: false, stops at the end of the hint", ctx do
      spend("#{ctx.mint1}_0", ctx.mint2, 0)
      assert %{mints: 1} = OrdinalCollections.sync(ctx.cid, [ctx.mint1], follow: false)
    end

    test "is idempotent and keeps traced ownership", ctx do
      OrdinalCollections.sync(ctx.cid, [ctx.mint1, ctx.mint2])
      item = Repo.get_by!(Item, origin: "#{ctx.mint1}_1")
      item |> Ecto.Changeset.change(owner: "1Traced", trace_state: "current") |> Repo.update!()

      assert %{mints: 2} = OrdinalCollections.sync(ctx.cid, [ctx.mint1, ctx.mint2])
      assert Repo.get_by!(Item, origin: "#{ctx.mint1}_1").owner == "1Traced"
    end
  end

  describe "trace/1" do
    setup ctx do
      OrdinalCollections.sync(ctx.cid, [ctx.mint1, ctx.mint2], follow: false)
      %{item: Repo.get_by!(Item, origin: "#{ctx.mint1}_1")}
    end

    test "an unspent item is current at its origin, owned by its lock", ctx do
      assert {:ok, traced} = OrdinalCollections.trace(ctx.item)
      assert traced.trace_state == "current"
      assert traced.current_outpoint == ctx.item.origin
      assert traced.owner == ctx.minter
      assert traced.trace_source == "index"
    end

    test "follows the sat by input offset: a 5000-sat input first puts it at output 1", ctx do
      funding = tx([funding_outpoint()], [p2pkh(address(), 5_000)]) |> publish()
      buyer = address()

      transfer =
        tx(["#{funding}_0", ctx.item.origin], [p2pkh(address(), 5_000), p2pkh(buyer, 1)])
        |> publish()

      spend(ctx.item.origin, transfer, 1)

      assert {:ok, traced} = OrdinalCollections.trace(ctx.item)
      assert traced.trace_state == "current"
      assert traced.current_outpoint == "#{transfer}_1"
      assert traced.owner == buyer
    end

    test "a sat merged into a multi-sat output is unknown, not guessed", ctx do
      merged = tx([ctx.item.origin], [p2pkh(address(), 2)]) |> publish()
      spend(ctx.item.origin, merged, 0)

      assert {:ok, %{trace_state: "unknown", trace_reason: "sat moved into a 2-sat output"}} =
               OrdinalCollections.trace(ctx.item)
    end

    # 1sat.market purchases lock the bought item with P2PKH followed by an
    # OP_RETURN MAP note; the P2PKH is still the owner (Grand Tardinians 76).
    test "P2PKH followed by OP_RETURN data is owned by the P2PKH", ctx do
      buyer = address()
      %BSV.TxOut{script: %BSV.Script{chunks: lock}} = p2pkh(buyer, 1)

      note = [:OP_RETURN, "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", "SET", "app", "1sat.market"]
      out = %BSV.TxOut{satoshis: 1, script: %BSV.Script{chunks: lock ++ note}}
      purchase = tx([ctx.item.origin], [out]) |> publish()
      spend(ctx.item.origin, purchase, 0)

      assert {:ok, %{trace_state: "current", owner: ^buyer}} = OrdinalCollections.trace(ctx.item)
    end

    test "held by a contract (listed for sale): current, with no P2PKH owner", ctx do
      listing = tx([ctx.item.origin], [contract("ordlock")]) |> publish()
      spend(ctx.item.origin, listing, 0)

      assert {:ok, traced} = OrdinalCollections.trace(ctx.item)
      assert traced.trace_state == "current"
      assert traced.current_outpoint == "#{listing}_0"
      assert traced.owner == nil
    end

    test "a long trail stops as partial at the last outpoint, and the next trace resumes there",
         ctx do
      # A chain of transfers longer than one trace may follow.
      hops = OrdinalCollections.max_hops() + 2

      last =
        Enum.reduce(1..hops, ctx.item.origin, fn _, from ->
          next = tx([from], [p2pkh(address(), 1)]) |> publish()
          spend(from, next, 0)
          "#{next}_0"
        end)

      assert {:ok, partial} = OrdinalCollections.trace(ctx.item)
      assert partial.trace_state == "partial"
      assert partial.current_outpoint != ctx.item.origin

      assert {:ok, done} = OrdinalCollections.trace(partial)
      assert done.trace_state == "current"
      assert done.current_outpoint == last
    end

    test "records the trail it walked, and from: :origin rebuilds it", ctx do
      hop1 = tx([ctx.item.origin], [p2pkh(address(), 1)]) |> publish()
      spend(ctx.item.origin, hop1, 0)
      hop2 = tx(["#{hop1}_0"], [p2pkh(address(), 1)]) |> publish()
      spend("#{hop1}_0", hop2, 0)

      assert {:ok, traced} = OrdinalCollections.trace(ctx.item)
      assert traced.trail == [hop1, hop2]

      # A resumed trace keeps the trail; a re-walk from the origin rebuilds it.
      assert {:ok, again} = OrdinalCollections.trace(traced)
      assert again.trail == [hop1, hop2]

      assert {:ok, rewalked} = OrdinalCollections.trace(%{again | trail: []}, from: :origin)
      assert rewalked.trail == [hop1, hop2]
    end

    # infra, 2026-11-10: WhatsOnChain is a raw-tx source only. Where an item
    # went comes from our spend index; a claim from WoC's `/spent` is never
    # asked for, let alone believed.
    test "a trace asks WhatsOnChain for raw txs and nothing else", ctx do
      # An input ahead of the item that we don't hold: its value sets the
      # sat's offset, so its raw tx is fetched.
      funding = tx([funding_outpoint()], [p2pkh(address(), 5_000)]) |> publish()
      buyer = address()

      transfer =
        tx(["#{funding}_0", ctx.item.origin], [p2pkh(address(), 5_000), p2pkh(buyer, 1)])
        |> publish()

      spend(ctx.item.origin, transfer, 1)
      Process.delete(:woc_calls)

      # Contradicts our index; must not be read.
      woc_spend("#{transfer}_1", String.duplicate("d", 64), 0)

      assert {:ok, %{trace_state: "current", owner: ^buyer} = traced} =
               OrdinalCollections.trace(ctx.item)

      assert traced.current_outpoint == "#{transfer}_1"
      calls = Process.get(:woc_calls, [])
      assert calls != []
      assert Enum.all?(calls, &match?({:txs, _}, &1))
      assert [{:txs, [[^funding]]}] = calls
    end

    test "an item our index can't answer for yet stays untraced, naming the height", ctx do
      # Blocks 117..120 are headers only: a spend there isn't indexed yet.
      index_through(116, 120)

      assert {:ok, traced} = OrdinalCollections.trace(ctx.item)
      assert traced.trace_state == "untraced"
      assert traced.current_outpoint == ctx.item.origin
      assert traced.owner == nil
      assert traced.trace_error == nil

      assert traced.trace_reason ==
               "no spend of #{ctx.item.origin} in our spend index, which is complete through " <>
                 "block 116 of 120; a spend from block 117 on isn't indexed yet"
    end

    test "a current item our index falls behind on is partial where it sat, and current again once it catches up",
         ctx do
      assert {:ok, current} = OrdinalCollections.trace(ctx.item)
      assert current.trace_state == "current"

      index_through(118, 121)
      assert {:ok, behind} = OrdinalCollections.trace(current)
      assert behind.trace_state == "partial"
      assert behind.current_outpoint == current.current_outpoint
      assert behind.owner == nil
      assert behind.trace_reason =~ "complete through block 118 of 121"
      assert behind.trace_reason =~ "the next trace continues from here"
      assert behind.trace_source == "index"

      index_through(121)
      assert {:ok, again} = OrdinalCollections.trace(behind)
      assert again.trace_state == "current"
      assert again.owner == ctx.minter
    end

    test "an item that moved, then reached blocks our index hasn't synced, is partial where it got to",
         ctx do
      index_through(118, 120)
      hop = tx([ctx.item.origin], [p2pkh(address(), 1)]) |> publish(118)
      spend(ctx.item.origin, hop, 0)

      assert {:ok, moved} = OrdinalCollections.trace(ctx.item)
      assert moved.trace_state == "partial"
      assert moved.current_outpoint == "#{hop}_0"
      assert moved.trail == [hop]
      assert moved.trace_reason =~ "complete through block 118 of 120"
    end

    test "a spend by a tx we don't hold leaves the item partial at its last outpoint", ctx do
      assert {:ok, current} = OrdinalCollections.trace(ctx.item)
      missing = String.duplicate("e", 64)
      spend(current.current_outpoint, missing, 0)

      assert {:ok, moved} = OrdinalCollections.trace(current)
      assert moved.trace_state == "partial"
      assert moved.current_outpoint == current.current_outpoint

      assert moved.trace_reason ==
               "#{current.current_outpoint} is spent by #{missing}, which isn't in a block we " <>
                 "store; the next trace continues from here"
    end

    # #46: a failed fetch never erases what was known. The item is known spent
    # from where it sat, so it stops there, and the next run retries.
    test "input txs that can't be fetched leave the item partial where it sat, and a later run finishes",
         ctx do
      assert {:ok, current} = OrdinalCollections.trace(ctx.item)
      funding = tx([funding_outpoint()], [p2pkh(address(), 5_000)]) |> publish()
      buyer = address()

      transfer =
        tx(["#{funding}_0", current.current_outpoint], [p2pkh(address(), 5_000), p2pkh(buyer, 1)])
        |> publish()

      spend(current.current_outpoint, transfer, 1)
      Process.put(:woc_txs_error, :timeout)

      assert {:ok, stuck} = OrdinalCollections.trace(current)
      assert stuck.trace_state == "partial"
      assert stuck.current_outpoint == current.current_outpoint
      assert stuck.trace_error == "input values of #{transfer} unavailable"
      assert stuck.traced_at == current.traced_at
      assert %DateTime{} = stuck.trace_checked_at

      Process.delete(:woc_txs_error)

      assert {:ok, %{trace_state: "current", owner: ^buyer, trace_error: nil}} =
               OrdinalCollections.trace(stuck)
    end
  end

  describe "trace_batch/1" do
    setup ctx do
      OrdinalCollections.sync(ctx.cid, [ctx.mint1, ctx.mint2], follow: false)
      %{items: Repo.all(from i in Item, where: i.collection_id == ^ctx.cid, order_by: i.id)}
    end

    test "moves every item a hop at a time, fetching the raw txs a hop lacks once, in bulk",
         ctx do
      [a, b] = ctx.items
      funding = tx([funding_outpoint()], [p2pkh(address(), 5_000)]) |> publish()
      buyer = address()

      # One tx moves both items; the sat offsets need the funding input's value.
      swap =
        tx(["#{funding}_0", a.origin, b.origin], [
          p2pkh(address(), 5_000),
          p2pkh(buyer, 1),
          p2pkh(buyer, 1)
        ])
        |> publish()

      spend(a.origin, swap, 1)
      Process.delete(:woc_calls)

      assert {:ok, [ta, tb], stats} = OrdinalCollections.trace_batch([a, b])
      assert {ta.current_outpoint, tb.current_outpoint} == {"#{swap}_1", "#{swap}_2"}
      assert ta.owner == buyer and tb.owner == buyer

      assert %{items: 2, hops: 2, raw_txs_fetched: 1, woc_requests: 1, spend_lookups: 4} =
               stats

      assert [{:txs, [[^funding]]}] = Process.get(:woc_calls)
    end

    test "a re-sync checks every item's outpoint and reads nothing for those that stayed",
         ctx do
      {:ok, traced, _} = OrdinalCollections.trace_batch(ctx.items)
      assert Enum.all?(traced, &(&1.trace_state == "current"))

      assert {:ok, again, stats} = OrdinalCollections.trace_batch(traced)
      assert Enum.map(again, & &1.owner) == Enum.map(traced, & &1.owner)
      assert %{hops: 1, spend_lookups: 2, tx_reads: 0, raw_txs_fetched: 0} = stats
    end
  end

  describe "import_txs/1" do
    test "stores only what's missing and reports what WoC didn't return", ctx do
      absent = String.duplicate("a", 64)

      assert %{stored: 1, existing: 0, failed: [{^absent, :not_returned}]} =
               OrdinalCollections.import_txs([ctx.mint1, absent])

      assert %{stored: 0, existing: 1, failed: []} = OrdinalCollections.import_txs([ctx.mint1])
    end
  end
end
