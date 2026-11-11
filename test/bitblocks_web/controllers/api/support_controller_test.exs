defmodule BitblocksWeb.Api.SupportControllerTest do
  # Mutates application env, so not async.
  use BitblocksWeb.ConnCase

  import Bitblocks.ChainFixtures

  @address "19JJzPiWzWKPQWMa6zj7JqPyYEMoP2xwEr"

  setup do
    original = Application.get_env(:bitblocks, :support)
    on_exit(fn -> Application.put_env(:bitblocks, :support, original) end)

    # The index counts blocks 0..complete_through; these tests store gifts at 0.
    block_fixture(%{height: 0, sync_state: "completed"})
    :ok
  end

  defp configure(opts) do
    Application.put_env(
      :bitblocks,
      :support,
      Keyword.merge([monthly_costs: [], sponsor_url: nil, bsv_address: nil], opts)
    )
  end

  defp paid(address, value),
    do: %{"n" => 0, "value" => value, "scriptPubKey" => %{"addresses" => [address]}}

  defp stored_gift(address, value, attrs \\ %{}) do
    transaction_fixture(
      Map.merge(
        %{
          block_height: 0,
          output_addresses: [address],
          outputs: [Jason.encode!(paid(address, value))],
          output_count: 1
        },
        attrs
      )
    )
  end

  test "without configuration it publishes no numbers", %{conn: conn} do
    configure([])
    data = conn |> get(~p"/api/v1/support") |> json_response(200) |> Map.fetch!("data")

    assert data["costs"] == []
    assert data["monthly_target_usd"] == nil
    assert data["received_sats_total"] == nil
    assert data["received_sources"] == []
  end

  test "sums configured costs into the monthly target", %{conn: conn} do
    configure(monthly_costs: [{"Node", 900}, {"Database", 100}])
    data = conn |> get(~p"/api/v1/support") |> json_response(200) |> Map.fetch!("data")

    assert data["monthly_target_usd"] == 1000
    assert %{"item" => "Node", "usd" => 900} in data["costs"]
  end

  test "reports BSV received at the donation address from the index", %{conn: conn} do
    configure(bsv_address: @address)
    stored_gift(@address, 0.5)

    conn = get(conn, ~p"/api/v1/support")
    data = json_response(conn, 200)["data"]

    assert data["received_sats_total"] == 50_000_000
    assert data["bsv_address"] == @address
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "a gift above complete_through waits for the sync, and the summary says so",
       %{conn: conn} do
    configure(bsv_address: @address)
    stored_gift(@address, 0.5)
    for h <- 1..5, do: block_fixture(%{height: h, sync_state: "header_only"})
    stored_gift(@address, 0.25, %{block_height: 5})

    # WhatsOnChain would know about the newer gift; we never ask it.
    Process.put(:woc_address_history, %{
      {@address, nil} => %{history: [%{txid: "recent", height: 5}], next_token: nil}
    })

    data = conn |> get(~p"/api/v1/support") |> json_response(200) |> Map.fetch!("data")

    assert data["received_sats_total"] == 50_000_000
    assert data["received_through_height"] == 0
    assert data["received_pending_from_height"] == 1
    assert data["received_note"] =~ "Gifts in later blocks count once the sync reaches them."

    assert [%{"source" => "index", "from_height" => 0, "through_height" => 0}] =
             data["received_sources"]
  end

  test "the 30-day figure is nil with a reason until the index reaches that window",
       %{conn: conn} do
    configure(bsv_address: @address)
    stored_gift(@address, 0.5)
    block_fixture(%{height: 5_000, sync_state: "header_only"})

    data = conn |> get(~p"/api/v1/support") |> json_response(200) |> Map.fetch!("data")

    assert data["received_sats_30d"] == nil
    assert data["received_30d_reason"] =~ "The last 30 days start at block"
    assert data["received_sats_total"] == 50_000_000
  end

  test "change back to the donation address is not counted as received", %{conn: conn} do
    pubkey = BSV.PrivKey.new() |> BSV.PubKey.from_privkey()
    address = pubkey |> BSV.Address.from_pubkey() |> BSV.Address.to_string()
    key = BSV.PubKey.to_binary(pubkey)
    unlock = Base.encode16(<<71>> <> :binary.copy(<<1>>, 71) <> <<33>> <> key)
    configure(bsv_address: address)

    stored_gift(address, 0.5)

    stored_gift(address, 0.4, %{
      inputs: [Jason.encode!(%{"txid" => "aa", "vout" => 0, "scriptSig" => %{"hex" => unlock}})]
    })

    data = conn |> get(~p"/api/v1/support") |> json_response(200) |> Map.fetch!("data")
    assert data["received_sats_total"] == 50_000_000
  end

  test "the footer links to the sponsor page only when configured", %{conn: conn} do
    configure([])
    refute conn |> get(~p"/about") |> html_response(200) =~ ">\n              Sponsor"

    configure(sponsor_url: "https://visibledao.com/bitblocks")
    assert conn |> get(~p"/about") |> html_response(200) =~ "https://visibledao.com/bitblocks"
  end
end
