defmodule BitblocksWeb.Api.SupportControllerTest do
  # Mutates application env, so not async.
  use BitblocksWeb.ConnCase

  import Bitblocks.ChainFixtures

  @address "19JJzPiWzWKPQWMa6zj7JqPyYEMoP2xwEr"

  setup do
    original = Application.get_env(:bitblocks, :support)
    on_exit(fn -> Application.put_env(:bitblocks, :support, original) end)
  end

  defp configure(opts) do
    Application.put_env(
      :bitblocks,
      :support,
      Keyword.merge([monthly_costs: [], sponsor_url: nil, bsv_address: nil], opts)
    )
  end

  test "without configuration it publishes no numbers", %{conn: conn} do
    configure([])
    data = conn |> get(~p"/api/v1/support") |> json_response(200) |> Map.fetch!("data")

    assert data["costs"] == []
    assert data["monthly_target_usd"] == nil
    assert data["received_sats_total"] == nil
  end

  test "sums configured costs into the monthly target", %{conn: conn} do
    configure(monthly_costs: [{"Node", 900}, {"Database", 100}])
    data = conn |> get(~p"/api/v1/support") |> json_response(200) |> Map.fetch!("data")

    assert data["monthly_target_usd"] == 1000
    assert %{"item" => "Node", "usd" => 900} in data["costs"]
  end

  test "reports BSV received at the donation address from the index", %{conn: conn} do
    configure(bsv_address: @address)

    transaction_fixture(%{
      output_addresses: [@address],
      outputs: [
        Jason.encode!(%{
          "n" => 0,
          "value" => 0.5,
          "scriptPubKey" => %{"addresses" => [@address]}
        })
      ],
      output_count: 1
    })

    conn = get(conn, ~p"/api/v1/support")
    data = json_response(conn, 200)["data"]

    assert data["received_sats_total"] == 50_000_000
    assert data["bsv_address"] == @address
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "the footer links to the sponsor page only when configured", %{conn: conn} do
    configure([])
    refute conn |> get(~p"/about") |> html_response(200) =~ ">\n              Sponsor"

    configure(sponsor_url: "https://visibledao.com/bitblocks")
    assert conn |> get(~p"/about") |> html_response(200) =~ "https://visibledao.com/bitblocks"
  end
end
