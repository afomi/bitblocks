defmodule Bitblocks.OrdinalCollections.RunJigTest do
  @moduledoc """
  #30 part 2: Run (RelayX) collections, Rexxies first. Mints and moves are
  read from Run's payload, not guessed from dust outputs.
  """
  use Bitblocks.DataCase, async: true

  import Bitblocks.OrdinalFixtures

  alias Bitblocks.OrdinalCollections
  alias Bitblocks.OrdinalCollections.{Item, RunJig}

  @rexxies OrdinalCollections.known()["rexxies"]

  defmodule TestCatalog do
    def entry(_txid),
      do: %{name: "Rexxie #7", traits: [%{"name" => "eye", "value" => "Confused"}]}
  end

  # A RelayX-shaped mint: output 0 the encrypted image, output 1 the Run
  # payload, output 2 the class's next location, output 3 the new NFT.
  defp mint(link, minter, opts \\ []) do
    method = Keyword.get(opts, :method, "mint")
    out = if method == "mint", do: ["class-state", "nft-state"], else: ["class-state"]

    tx([link, funding_outpoint()], [
      data_output(),
      run_payload(%{"in" => 1, "out" => out, "cre" => [minter], "exec" => [run_call(0, method)]}),
      p2pkh(minter, 273),
      p2pkh(minter, 273),
      p2pkh(address(), 9_000)
    ])
  end

  defp decode({_txid, hex}) do
    {:ok, tx} = Bitblocks.Chain.RawTx.parse(hex)
    tx
  end

  describe "payload/1" do
    test "finds the Run payload and its output index" do
      tx = decode(mint(funding_outpoint(), address()))
      assert {:ok, 1, %{"in" => 1, "exec" => [%{"op" => "CALL"}]}} = RunJig.payload(tx)
    end
  end

  describe "mint/4" do
    test "a mint call on the chain link yields the created NFT and the class's next link" do
      link = funding_outpoint()
      minter = address()
      {txid, _} = built = mint(link, minter)

      assert {:ok, [item], [next]} =
               RunJig.mint(decode(built), txid, link, %{id: link, catalog: TestCatalog})

      assert item.vout == 3
      assert item.owner == minter
      assert item.name == "Rexxie #7"
      assert next == "#{txid}_2"
    end

    test "a non-mint call carries the chain on with no items" do
      link = funding_outpoint()
      {txid, _} = built = mint(link, address(), method: "setPrice")

      assert {:ok, [], ["#{txid}_2"]} == RunJig.mint(decode(built), txid, link, %{id: link})
    end

    test "states its own membership rule for the verification block" do
      assert RunJig.rule() =~ "calls mint"
      refute RunJig.rule() =~ "collectionItem"
      assert Bitblocks.OrdinalCollections.verification(@rexxies).rule == RunJig.rule()
    end

    test "a tx that doesn't spend the link isn't a mint" do
      {txid, _} = built = mint(funding_outpoint(), address())
      assert :no == RunJig.mint(decode(built), txid, funding_outpoint(), %{id: "x"})
    end
  end

  describe "landing/4" do
    defp send_tx(inputs, jigs_in, opts \\ []) do
      outs = for _ <- 1..jigs_in, do: p2pkh(address(), 273)

      tx(
        inputs,
        [
          run_payload(%{
            "in" => jigs_in,
            "out" => List.duplicate("h", jigs_in),
            "del" => opts[:del] || []
          })
          | outs
        ]
      )
    end

    test "a jig spent as input i lands at payload + 1 + i (batch sends included)" do
      {txid, _} = built = send_tx([funding_outpoint(), funding_outpoint(), funding_outpoint()], 3)
      noop = fn _ -> :error end

      assert {:ok, "#{txid}_1"} == RunJig.landing(decode(built), txid, 0, noop)
      assert {:ok, "#{txid}_3"} == RunJig.landing(decode(built), txid, 2, noop)
    end

    test "deletes, non-jig inputs and non-Run spends are unknown" do
      noop = fn _ -> :error end

      {t1, _} = b1 = send_tx([funding_outpoint()], 1, del: ["gone"])
      assert {:unknown, reason} = RunJig.landing(decode(b1), t1, 0, noop)
      assert reason == "#{t1} deletes jigs; output mapping needs jig state"

      {t2, _} = b2 = send_tx([funding_outpoint(), funding_outpoint()], 1)
      assert {:unknown, "spent as a non-jig input" <> _} = RunJig.landing(decode(b2), t2, 1, noop)

      {t3, _} = b3 = tx([funding_outpoint()], [p2pkh(address(), 500)])
      assert {:error, _} = RunJig.landing(decode(b3), t3, 0, noop)
    end

    # #46: a non-Run spend of a jig's standard 273-sat output destroys it; the
    # trail ends. A 1-sat output is a doubt (the trace may have followed the
    # wrong output), so it stays unknown.
    test "a non-Run spend ends the trail only from a 273-sat jig output" do
      {txid, _} = built = tx([funding_outpoint()], [p2pkh(address(), 500)])

      assert {:ended, "spent outside Run in " <> _} =
               RunJig.landing(decode(built), txid, 0, fn _ -> {:ok, 273} end)

      assert {:unknown, "spent outside Run in " <> _} =
               RunJig.landing(decode(built), txid, 0, fn _ -> {:ok, 1} end)

      assert {:error, "input values of " <> _} =
               RunJig.landing(decode(built), txid, 0, fn _ -> :error end)
    end

    test "the ended rule matches #46's classification: 30 strong end, 5 open doubts don't" do
      data =
        "docs/field-notes/data/rexxies-spent-outside-run-2026-11-02.json"
        |> File.read!()
        |> Jason.decode!()

      ended = for e <- data, RunJig.ends_trail?(e["jig_sats"]), do: e["item"]
      strong = for e <- data, e["confidence"] == "strong", do: e["item"]

      assert length(strong) == 30
      assert Enum.sort(ended) == Enum.sort(strong)
    end
  end

  describe "the Rexxies collection" do
    test "proves mints along the class chain, through non-mint calls, rejecting fakes" do
      minter = address()
      mint1 = mint(@rexxies, minter) |> publish(771_246)
      update = mint("#{mint1}_2", minter, method: "setPrice") |> publish(771_247)
      mint2 = mint("#{update}_2", minter) |> publish(771_248)
      fake = mint(funding_outpoint(), minter) |> publish(771_249)

      # The hint has mint 1 and the fake; the update and mint 2 are found by
      # following the class's chain.
      spend("#{mint1}_2", update, 0)
      spend("#{update}_2", mint2, 0)

      assert %{mints: 2, items: 2, rejected: 1} = OrdinalCollections.sync(@rexxies, [mint1, fake])

      origins = Repo.all(from i in Item, where: i.collection_id == ^@rexxies, select: i.origin)
      assert Enum.sort(origins) == Enum.sort(["#{mint1}_3", "#{mint2}_3"])
    end

    test "traces a Rexxie through a batch send to its holder" do
      minter = address()
      mint1 = mint(@rexxies, minter) |> publish(771_246)
      OrdinalCollections.sync(@rexxies, [mint1], follow: false)
      item = Repo.get_by!(Item, origin: "#{mint1}_3")

      buyer = address()

      batch =
        tx([funding_outpoint(), item.origin], [
          run_payload(%{
            "in" => 2,
            "out" => ["a", "b"],
            "exec" => [run_call(0, "send"), run_call(1, "send")]
          }),
          p2pkh(address(), 273),
          p2pkh(buyer, 273)
        ])
        |> publish()

      spend(item.origin, batch, 1)

      assert {:ok, traced} = OrdinalCollections.trace(item)
      assert traced.trace_state == "current"
      assert traced.current_outpoint == "#{batch}_2"
      assert traced.owner == buyer
    end

    test "a Rexxie consolidated out of Run reads ended, settled, and stays ended" do
      mint1 = mint(@rexxies, address()) |> publish(771_246)
      OrdinalCollections.sync(@rexxies, [mint1], follow: false)
      item = Repo.get_by!(Item, origin: "#{mint1}_3")

      consolidation =
        tx([funding_outpoint(), item.origin], [p2pkh(address(), 9_273)]) |> publish()

      spend(item.origin, consolidation, 1)

      assert {:ok, ended} = OrdinalCollections.trace(item)
      assert ended.trace_state == "ended"
      assert ended.current_outpoint == item.origin
      assert ended.owner == nil
      assert ended.trail == [consolidation]
      assert ended.trace_reason =~ "spent outside Run in #{consolidation}"
      assert OrdinalCollections.settled_state?("ended")
      assert %{traced: 1, ended: 1} = OrdinalCollections.get_collection("rexxies")
      assert OrdinalCollections.ownership_sentence(ended) =~ "No holder"

      # A re-check ends the same way; a failed one keeps it ended.
      assert {:ok, %{trace_state: "ended", trail: [^consolidation]}} =
               OrdinalCollections.trace(ended)

      Process.put(:woc_spent, %{item.origin => {:error, :timeout}})
      assert {:ok, %{trace_state: "ended"}} = OrdinalCollections.trace(ended)
    end

    test "a stranger is false once every Rexxie is current or ended" do
      mint1 = mint(@rexxies, address()) |> publish(771_246)
      OrdinalCollections.sync(@rexxies, [mint1])
      item = Repo.get_by!(Item, origin: "#{mint1}_3")
      stranger = "#{String.duplicate("c", 64)}_0"

      consolidation = tx([item.origin], [p2pkh(address(), 273)]) |> publish()
      spend(item.origin, consolidation, 0)
      assert %{"ended" => 1} = OrdinalCollections.trace_all(@rexxies)

      assert %{^stranger => {false, _}} = OrdinalCollections.absence(@rexxies, [stranger])
    end
  end
end
