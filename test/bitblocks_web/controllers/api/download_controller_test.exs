defmodule BitblocksWeb.Api.DownloadControllerTest do
  # GET /api/v1/downloads/quote (https://github.com/afomi/bitblocks/issues/111):
  # the free quote for agents, from stored block sizes.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures

  setup do
    for {size, height} <- Enum.with_index([285, 1_000, 2_000]) do
      block_fixture(%{height: height, size: size, sync_state: "completed"})
    end

    block_fixture(%{height: 3, size: 5_000, sync_state: "header_only"})
    :ok
  end

  test "quotes a range with no price set", %{conn: conn} do
    body =
      conn
      |> get(~p"/api/v1/downloads/quote?from=1&to=2&data=raw")
      |> json_response(200)

    assert %{
             "from" => 1,
             "to" => 2,
             "data" => "raw",
             "format" => "bin",
             "files" => 2,
             "bytes" => 3_000,
             "bytes_exact" => true,
             "sizes_missing" => 0,
             "complete_through" => 2,
             "price_usd" => nil,
             "price" => "on_request",
             "checkout" => "not_built"
           } = body["data"]

    assert body["data"]["contact"] =~ "mailto:"
    assert body["meta"]["size_source"] == "blocks.size"
  end

  test "refuses a range above complete_through with that height", %{conn: conn} do
    body =
      conn
      |> get(~p"/api/v1/downloads/quote?from=0&to=3&data=raw")
      |> json_response(422)

    assert body["error"] == "above_complete_through"
    assert body["complete_through"] == 2
    assert body["message"] =~ "through 2"
  end

  test "refuses data that is coming", %{conn: conn} do
    body =
      conn
      |> get(~p"/api/v1/downloads/quote?from=0&to=1&data=tx_json")
      |> json_response(422)

    assert body["error"] == "coming"
  end

  describe "with a price per GiB" do
    setup do
      previous = Application.get_env(:bitblocks, Bitblocks.Downloads)
      Application.put_env(:bitblocks, Bitblocks.Downloads, price_usd_per_gib: "1.00")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:bitblocks, Bitblocks.Downloads, previous),
          else: Application.delete_env(:bitblocks, Bitblocks.Downloads)
      end)
    end

    test "quotes the price with the fields it comes from", %{conn: conn} do
      body =
        conn
        |> get(~p"/api/v1/downloads/quote?from=0&to=2&data=raw")
        |> json_response(200)

      assert %{
               "bytes" => 3_285,
               "billable_gib" => "0.01",
               "price_usd_per_gib" => "1.00",
               "price_usd" => "0.01",
               "price" => "quoted",
               "price_reason" => nil
             } = body["data"]

      assert body["meta"]["pricing"] =~ "billable_gib x price_usd_per_gib"
      assert body["meta"]["check"] =~ "merkleroot"
    end

    test "names why a range with a missing size has no price", %{conn: conn} do
      block_fixture(%{height: 4, size: nil, sync_state: "completed"})
      Bitblocks.Repo.update_all(Bitblocks.Chain.Block, set: [sync_state: "completed"])

      body =
        conn
        |> get(~p"/api/v1/downloads/quote?from=0&to=4&data=raw")
        |> json_response(200)

      assert %{"price_usd" => nil, "price" => "on_request", "price_reason" => "sizes_missing"} =
               body["data"]
    end
  end

  test "says no price is set while none is configured", %{conn: conn} do
    body = conn |> get(~p"/api/v1/downloads/quote?from=0&to=0&data=raw") |> json_response(200)
    assert body["data"]["price_reason"] == "no_price_set"
    assert body["data"]["price_usd_per_gib"] == nil
  end

  describe "GET /api/v1/downloads/sizes" do
    setup do
      Bitblocks.Downloads.clear_size_bands()
      on_exit(&Bitblocks.Downloads.clear_size_bands/0)
    end

    test "gives each band's size and the named ranges", %{conn: conn} do
      body = conn |> get(~p"/api/v1/downloads/sizes") |> json_response(200)

      assert [%{"from" => 0, "to" => 2, "blocks" => 3, "bytes" => 3_285, "bytes_exact" => true}] =
               body["data"]

      assert body["meta"]["complete_through"] == 2
      assert body["meta"]["band_size"] == 50_000

      assert %{"id" => "all", "from" => 0, "to" => 2, "available" => true} =
               Enum.find(body["meta"]["presets"], &(&1["id"] == "all"))
    end
  end
end
