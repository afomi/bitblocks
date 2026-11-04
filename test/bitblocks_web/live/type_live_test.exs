defmodule BitblocksWeb.TypeLiveTest do
  # The LiveView process reads rows the test inserts.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures
  import Phoenix.LiveViewTest

  alias Bitblocks.TxTypes

  defp txid(n), do: n |> Integer.to_string(16) |> String.pad_leading(64, "0") |> String.downcase()

  describe "index" do
    test "lists every type in its group, each linking to its page", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/types")

      assert html =~ "Bitcoin SV transaction types"

      for type <- TxTypes.all() do
        assert has_element?(
                 view,
                 ~s(#group-#{type.group} a#type-#{type.id}[href="/types/#{type.id}"])
               )
      end
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

    test "an index with nothing yet says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/types/metanet")
      assert has_element?(view, "#type-examples-empty")
    end

    test "a type with no cheap source says examples are coming", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/types/op-return")
      assert has_element?(view, "#type-examples-coming", "Examples coming.")
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
