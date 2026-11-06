defmodule BitblocksWeb.ProtocolsLiveTest do
  # "Proven" is earned on chain, as on /bitcom (#9). A seed doesn't earn it.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bitblocks.ProtocolRegistry

  @address "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

  defp protocol(attrs) do
    {:ok, protocol} =
      ProtocolRegistry.create_protocol(
        Map.merge(
          %{address: @address, name: "Seeded", category: :data_storage},
          attrs
        )
      )

    protocol
  end

  test "a seeded protocol reads Curated, never Verified", %{conn: conn} do
    protocol = protocol(%{verification_status: :verified})

    {:ok, view, html} = live(conn, ~p"/protocols")

    refute html =~ "Verified"
    assert html =~ "Curated"

    html = view |> render_click("select_protocol", %{"protocol" => to_string(protocol.id)})
    assert html =~ "No on-chain proof yet"
    refute html =~ ~s(id="protocol-proof")
  end

  test "a protocol with an on-chain proof reads Proven and links the proof", %{conn: conn} do
    txid = String.duplicate("ab", 32)
    protocol = protocol(%{verification_status: :unverified, ownership_proof_txid: txid})

    {:ok, view, html} = live(conn, ~p"/protocols")

    assert html =~ "Proven"

    render_click(view, "select_protocol", %{"protocol" => to_string(protocol.id)})

    assert has_element?(view, "#protocol-trust", "Proven")
    assert has_element?(view, ~s(#protocol-proof a[href="/transactions/#{txid}"]))
    assert has_element?(view, ~s(#protocol-proof a[href="/bitcom/#{@address}"]))
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
