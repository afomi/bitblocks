defmodule BitblocksWeb.TypeLiveTest do
  # The LiveView process reads rows the test inserts.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures
  import Phoenix.LiveViewTest

  alias Bitblocks.TxTypes

  # An element's text, tags dropped and whitespace collapsed.
  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
  end

  defp txid(n), do: n |> Integer.to_string(16) |> String.pad_leading(64, "0") |> String.downcase()

  describe "index" do
    test "lists every type in its group, each linking to its page", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/types")

      assert html =~ "Bitcoin transaction types"

      for type <- TxTypes.all() do
        assert has_element?(
                 view,
                 ~s(#group-#{type.group} a#type-#{type.id}[href="/types/#{type.id}"])
               )
      end
    end
  end

  describe "index layers and registry" do
    @address "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

    defp protocol(attrs) do
      {:ok, protocol} =
        Bitblocks.ProtocolRegistry.create_protocol(
          Map.merge(%{address: @address, name: "Seeded", category: :data_storage}, attrs)
        )

      protocol
    end

    test "/protocols moves here for good", %{conn: conn} do
      conn = get(conn, "/protocols")

      assert conn.status == 301
      assert redirected_to(conn, 301) == "/types#protocols"
    end

    test "the four layers sit above the types, the top one pointing at the registry", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/types")

      for level <- 1..4, do: assert(has_element?(view, "#layer-#{level}"))
      assert has_element?(view, ~s(#layer-4 a[href="#protocols"]))
    end

    test "a seeded protocol reads Curated, never Verified", %{conn: conn} do
      protocol = protocol(%{verification_status: :verified})

      {:ok, view, _html} = live(conn, ~p"/types")

      assert has_element?(view, "#protocol-#{protocol.id} .protocol-trust", "Curated")
      assert has_element?(view, "#protocol-#{protocol.id}", "No on-chain proof yet")
      refute has_element?(view, "#protocol-#{protocol.id} .protocol-proof")
    end

    test "a protocol with an on-chain proof reads Proven and links the proof", %{conn: conn} do
      txid = String.duplicate("ab", 32)
      protocol = protocol(%{verification_status: :unverified, ownership_proof_txid: txid})

      {:ok, view, _html} = live(conn, ~p"/types")
      row = "#protocol-#{protocol.id}"

      assert has_element?(view, "#{row} .protocol-trust", "Proven")
      assert has_element?(view, ~s(#{row} .protocol-proof a[href="/transactions/#{txid}"]))
      assert has_element?(view, ~s(#{row} .protocol-proof a[href="/bitcom/#{@address}"]))
    end

    test "a protocol that is also a type links to it, and one that isn't doesn't", %{conn: conn} do
      typed = protocol(%{name: "BSV21"})
      untyped = protocol(%{address: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT", name: "Unmatched"})

      {:ok, view, _html} = live(conn, ~p"/types")

      assert has_element?(view, ~s(#protocol-#{typed.id} a[href="/types/bsv-21"]))
      refute has_element?(view, ~s(#protocol-#{untyped.id} a[href^="/types/"]))
    end

    test "the API says which protocols are proven", %{conn: conn} do
      txid = String.duplicate("cd", 32)
      protocol(%{verification_status: :verified, ownership_proof_txid: txid})

      %{"data" => data} = conn |> get("/api/v1/protocols") |> json_response(200)
      entry = Enum.find(data, &(&1["address"] == @address))

      assert entry["proven"] == true
      assert entry["ownership_proof_txid"] == txid
    end
  end

  describe "index counts (#49)" do
    test "each type shows its tx count and first block, custom included", %{conn: conn} do
      typed_block_fixture(0, %{"custom" => 1})
      typed_block_fixture(1, %{"custom" => 1_233, "p2pkh" => 2})
      Bitblocks.TxTypes.Counts.refresh()

      {:ok, view, _html} = live(conn, ~p"/types")

      assert text(view, "#type-custom-count") =~ "1,234 txs since block 0"
      assert text(view, "#type-p2pkh-count") =~ "2 txs since block 1"
      assert text(view, "#type-bsv-21-count") =~ "none yet"
    end

    test "says which range of the chain the counts cover", %{conn: conn} do
      typed_block_fixture(0, %{"custom" => 1})
      typed_block_fixture(1, %{"p2pkh" => 1})
      block_fixture(%{height: 2, sync_state: "header_only"})
      Bitblocks.TxTypes.Counts.refresh()

      {:ok, view, _html} = live(conn, ~p"/types")
      coverage = text(view, "#type-counts-coverage")

      assert coverage =~ "Counts cover blocks 0 to 1 of 2 known."
      assert coverage =~ "once under each"
    end

    test "before the first count, says counts are on their way", %{conn: conn} do
      :ets.delete(Bitblocks.TxTypes.Counts, :summary)

      {:ok, view, _html} = live(conn, ~p"/types")

      assert text(view, "#type-counts-coverage") =~ "being computed"
      refute has_element?(view, "#type-custom-count")
    end
  end

  describe "show" do
    test "every type page renders its description, pattern and spec link", %{conn: conn} do
      for type <- TxTypes.all() do
        {:ok, view, _html} = live(conn, ~p"/types/#{type.id}")

        assert has_element?(view, "h1", type.title)
        assert has_element?(view, "#type-description", hd(type.description))

        for part <- type.pattern.parts do
          assert has_element?(view, "#type-pattern code", part.token)
        end

        assert has_element?(view, ~s(a#type-spec-link[href="#{type.spec.url}"]))

        assert has_element?(view, "#type-spend", type.spend)

        for related <- TxTypes.related(type) do
          assert has_element?(view, ~s(#type-related a[href="/types/#{related.id}"]))
        end
      end
    end

    test "lists real examples from the index, each linking to its transaction", %{conn: conn} do
      transaction_fixture(%{txid: txid(1), block_height: 812_345, protocols: ["Metanet"]})
      transaction_fixture(%{txid: txid(2), block_height: 812_346, protocols: ["Metanet"]})

      {:ok, view, _html} = live(conn, ~p"/types/metanet")

      assert has_element?(view, ~s(#type-examples-list a[href="/transactions/#{txid(1)}"]))
      assert has_element?(view, ~s(#type-examples-list a[href="/transactions/#{txid(2)}"]))
      assert render(element(view, "#type-examples-list")) =~ "block 812,346"
    end

    test "shows first seen and adoption, and says which range it covers", %{conn: conn} do
      typed_block_fixture(0, %{"p2pkh" => 2})
      typed_block_fixture(1, %{"p2pkh" => 1_233})
      Bitblocks.TxTypes.Counts.refresh()

      {:ok, view, _html} = live(conn, ~p"/types/p2pkh")

      assert text(view, "#type-first-seen") =~ "First seen in block 0"
      assert text(view, "#type-adoption-coverage") =~ "Counts cover blocks 0 to 1"
      assert text(view, "#type-adoption-table") =~ "1,235"
    end

    test "with no counts yet, there is no adoption section", %{conn: conn} do
      Bitblocks.TxTypes.Counts.refresh()

      {:ok, view, _html} = live(conn, ~p"/types/p2pkh")

      refute has_element?(view, "#type-adoption")
    end

    test "an index with nothing yet says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/types/metanet")
      assert has_element?(view, "#type-examples-empty")
    end

    test "a typed source with no typed block holding one says examples are coming", %{conn: conn} do
      :ets.delete(Bitblocks.TxTypes.Counts, :summary)

      {:ok, view, _html} = live(conn, ~p"/types/op-return")
      assert has_element?(view, "#type-examples-coming", "Examples coming.")
    end

    test "a typed source lists txs from the typed blocks", %{conn: conn} do
      block = typed_block_fixture(0, %{"op-return" => 1})
      transaction_fixture(%{txid: txid(7), block_hash: block.hash, tx_types: ["op-return"]})
      Bitblocks.TxTypes.Counts.refresh()
      on_exit(fn -> :ets.delete(Bitblocks.TxTypes.Counts, :summary) end)

      {:ok, view, _html} = live(conn, ~p"/types/op-return")
      assert has_element?(view, "#type-examples-list a[href='/transactions/#{txid(7)}']")
    end

    test "Metanet shows the paper, its concepts and the CC BY-SA attribution", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/types/metanet")

      paper =
        "https://nchain.com/wp-content/uploads/2022/09/The-Metanet-Technical-Summary-v1.0.pdf"

      assert has_element?(view, ~s(a#type-spec-link[href="#{paper}"]))
      assert has_element?(view, ~s(#type-attribution a[href="#{paper}"]))
      assert has_element?(view, "#type-attribution", "nChain Limited")
      assert has_element?(view, ~s(#type-attribution a[rel~="license"]), "CC BY-SA 4.0")

      for id <- ~w(node edge root versions murl search insertion-methods) do
        assert has_element?(view, "#concept-#{id}")
      end
    end

    test "an unknown type is a 404", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/types/no-such-type") end
    end
  end
end
