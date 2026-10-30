defmodule Bitblocks.OrdinalCollectionsTest do
  @moduledoc """
  #30: 1Sat collections. Membership is proven by the mint-contract chain, not
  claimed by MAP; ownership follows the item's sat through spends.
  """
  use Bitblocks.DataCase, async: true

  import Bitblocks.OrdinalFixtures

  alias Bitblocks.OrdinalCollections
  alias Bitblocks.OrdinalCollections.Item
  alias Bitblocks.Ordinals.Inscription

  # A collection whose origin output 0 is the start of the mint chain, and two
  # mints: each spends the previous chain link and carries it on at output 0.
  setup do
    collection_txid = tx([funding_outpoint()], [contract("collection")]) |> publish(839_715)
    cid = "#{collection_txid}_0"
    minter = address()

    mint1 = tx([cid], [contract(), item(cid, "Tardinian 1", minter)]) |> publish(839_716)
    mint2 = tx(["#{mint1}_0"], [contract(), item(cid, "Tardinian 2", minter)]) |> publish(839_717)

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
      assert traced.trace_source == "whatsonchain"
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

    test "a WhatsOnChain failure is unknown with its reason", ctx do
      Process.put(:woc_spent, %{ctx.item.origin => {:error, :timeout}})

      assert {:ok, %{trace_state: "unknown", trace_reason: "whatsonchain: :timeout"}} =
               OrdinalCollections.trace(ctx.item)
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
