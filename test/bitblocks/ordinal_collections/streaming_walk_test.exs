defmodule Bitblocks.OrdinalCollections.StreamingWalkTest do
  @moduledoc """
  #47: a walk holds counts, not transactions. What a protocol reads from a tx
  is a slice of its bytes, so keeping every mint's items until the end of the
  job kept every mint's whole inscription alive. These tests walk real
  multi-hop chains and check the answers are exact and the memory is flat.
  """
  use Bitblocks.DataCase, async: true

  import Bitblocks.OrdinalFixtures

  alias Bitblocks.OrdinalCollections
  alias Bitblocks.OrdinalCollections.{Item, Walk}
  alias Bitblocks.Workers.CollectionTraceWorker

  @inscription_bytes 500_000

  # A chain of `count` mints, each carrying `content`.
  defp chain(count, content, trait \\ nil) do
    collection_txid = tx([funding_outpoint()], [contract("collection")]) |> publish(839_000)
    cid = "#{collection_txid}_0"
    owner = address()

    {mints, _} =
      Enum.map_reduce(1..count, cid, fn n, link ->
        out = item(cid, "Item #{n}", owner, [{"Rank", trait || "#{n}"}], content)
        mint = tx([link], [contract(), out]) |> publish(839_000 + n)
        spend(link, mint, 0)
        {mint, "#{mint}_0"}
      end)

    %{cid: cid, mints: mints, owner: owner}
  end

  describe "the answers" do
    test "a walk over many hops finds every mint in order, with its items exact" do
      %{cid: cid, mints: mints, owner: owner} = chain(5, "<svg/>")

      # Only the first two are hinted: the rest are found by following the chain.
      fake = tx([funding_outpoint()], [contract(), item(cid, "Fake", address())]) |> publish()
      hint = [Enum.at(mints, 0), Enum.at(mints, 1), fake]

      result = OrdinalCollections.sync(cid, hint)

      assert %{mints: 5, items: 5, rejected: 1, complete: true} = result
      assert result.import.failed == []

      items = Repo.all(from i in Item, where: i.collection_id == ^cid, order_by: i.id)

      assert Enum.map(items, & &1.mint_txid) == mints
      assert Enum.map(items, & &1.origin) == Enum.map(mints, &"#{&1}_1")
      assert Enum.map(items, & &1.name) == for(n <- 1..5, do: "Item #{n}")
      assert Enum.map(items, & &1.mint_height) == for(n <- 1..5, do: 839_000 + n)
      assert Enum.map(items, & &1.content_type) |> Enum.uniq() == ["image/svg+xml"]
      assert Enum.map(items, & &1.owner) |> Enum.uniq() == [owner]

      assert Enum.map(items, &(&1.traits |> hd() |> Map.fetch!("value"))) ==
               for(n <- 1..5, do: "#{n}")

      assert %{mints: 5, items: 5} = Repo.get_by!(Walk, collection_id: cid)

      assert OrdinalCollections.verification(cid).list_hash ==
               :crypto.hash(
                 :sha256,
                 mints |> Enum.map(&"#{&1}_1") |> Enum.sort() |> Enum.join("\n")
               )
               |> Base.encode16(case: :lower)
    end

    test "a chain that stops at a failed lookup keeps what it proved, and records no finished walk" do
      %{cid: cid, mints: [first, second | _]} = chain(3, "<svg/>")
      spent = Process.get(:woc_spent) |> Map.put("#{second}_0", {:error, :timeout})
      Process.put(:woc_spent, spent)

      assert %{mints: 2, items: 2, complete: false} = OrdinalCollections.sync(cid, [first])

      assert Repo.aggregate(from(i in Item, where: i.collection_id == ^cid), :count) == 2
      refute Repo.get_by(Walk, collection_id: cid)
    end

    test "a second walk changes nothing, and keeps traced ownership" do
      %{cid: cid, mints: [first | _] = mints} = chain(3, "<svg/>")
      assert %{mints: 3, items: 3} = OrdinalCollections.sync(cid, [first])

      holder = address()
      item = Repo.get_by!(Item, origin: "#{first}_1")
      moved = tx([item.origin], [p2pkh(holder, 1)]) |> publish()
      spend(item.origin, moved, 0)
      assert %{"current" => 3} = OrdinalCollections.trace_all(cid)

      assert %{mints: 3, items: 3, rejected: 0} = OrdinalCollections.sync(cid, mints)

      assert %{current_outpoint: outpoint, owner: ^holder, trail: [^moved]} =
               Repo.get_by!(Item, origin: "#{first}_1")

      assert outpoint == "#{moved}_0"
    end

    test "trace_all follows every item over many hops, past a page of items" do
      %{cid: cid, mints: [first | _]} = chain(3, "<svg/>")
      OrdinalCollections.sync(cid, [first])
      item = Repo.get_by!(Item, origin: "#{first}_1")

      holder = address()

      {last, trail} =
        Enum.reduce(1..4, {item.origin, []}, fn _, {from, trail} ->
          next = tx([from], [p2pkh(holder, 1)]) |> publish()
          spend(from, next, 0)
          {"#{next}_0", trail ++ [next]}
        end)

      assert %{"current" => 3} == OrdinalCollections.trace_all(cid)

      assert %{current_outpoint: ^last, owner: ^holder, trail: ^trail, trace_state: "current"} =
               Repo.get_by!(Item, origin: "#{first}_1")
    end
  end

  describe "the memory" do
    # One hop holds about seven times its inscription: its hex, its bytes and
    # what read them. Twenty mints held to the end would be twenty, and more.
    @long 20
    @one_hop 10 * @inscription_bytes

    # The BEAM copies a slice of 64 bytes or less out of its parent, and keeps
    # the parent alive for a longer one: a long trait pins the whole tx.
    @long_trait String.duplicate("a trait description past 64 bytes ", 3)

    defp walked(count) do
      content = :crypto.strong_rand_bytes(@inscription_bytes)
      %{cid: cid, mints: [first | _]} = chain(count, content, @long_trait)
      Map.put(OrdinalCollections.sync(cid, [first]), :cid, cid)
    end

    test "a walk of large mints holds one hop at a time" do
      walk = walked(@long)

      assert %{mints: @long, items: @long, complete: true} = walk
      assert walk.peak_bytes < @one_hop
      assert Repo.get_by!(Walk, collection_id: walk.cid).peak_bytes == walk.peak_bytes

      [item | _] = Repo.all(from i in Item, where: i.collection_id == ^walk.cid)
      assert hd(item.traits)["value"] == @long_trait
    end

    test "a trace batch holds one hop at a time, and the highest peak is kept" do
      assert %{cid: cid, complete: true, import: %{failed: []}} = walked(@long)
      ids = Repo.all(from i in Item, where: i.collection_id == ^cid, select: i.id)

      :ok =
        CollectionTraceWorker.perform(%Oban.Job{
          id: nil,
          args: %{
            "slug" => cid,
            "ids" => ids,
            "run_started_at" => DateTime.to_iso8601(DateTime.utc_now())
          }
        })

      peak = Repo.get_by!(Walk, collection_id: cid).trace_peak_bytes
      assert is_integer(peak)
      assert peak < @one_hop

      OrdinalCollections.record_trace_peak(cid, 0)
      assert Repo.get_by!(Walk, collection_id: cid).trace_peak_bytes == peak
      OrdinalCollections.record_trace_peak(cid, peak + 1)
      assert Repo.get_by!(Walk, collection_id: cid).trace_peak_bytes == peak + 1
    end
  end
end
