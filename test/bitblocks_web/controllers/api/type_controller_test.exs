defmodule BitblocksWeb.Api.TypeControllerTest do
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.TxTypes

  test "GET /api/v1/types lists every type with its page URL", %{conn: conn} do
    body = conn |> get(~p"/api/v1/types") |> json_response(200)

    assert body["count"] == length(TxTypes.all())
    assert Enum.map(body["data"], & &1["id"]) == TxTypes.ids()

    bsv21 = Enum.find(body["data"], &(&1["id"] == "bsv-21"))

    assert bsv21["url"] == BitblocksWeb.Endpoint.url() <> "/types/bsv-21"
    assert bsv21["api_url"] == BitblocksWeb.Endpoint.url() <> "/api/v1/types/bsv-21"

    for key <-
          ~w(title short group summary description history spec pattern spendable spend related),
        do: assert(Map.has_key?(bsv21, key), "missing #{key}")

    assert %{"label" => _, "url" => "https://" <> _} = bsv21["spec"]
    assert [%{"token" => _, "label" => _} | _] = bsv21["pattern"]["parts"]
    refute Map.has_key?(bsv21, "examples")
  end

  test "GET /api/v1/types/:id returns the type with examples from the index", %{conn: conn} do
    txid = String.duplicate("ab", 32)
    transaction_fixture(%{txid: txid, block_height: 812_345, protocols: ["MAP"]})

    data = conn |> get(~p"/api/v1/types/map") |> json_response(200) |> Map.fetch!("data")

    assert data["id"] == "map"
    assert data["url"] == BitblocksWeb.Endpoint.url() <> "/types/map"

    assert %{
             "status" => "ok",
             "kind" => "protocol",
             "protocols" => ["MAP"],
             "count" => nil,
             "transactions" => [example]
           } = data["examples"]

    assert example == %{
             "txid" => txid,
             "block_height" => 812_345,
             "note" => nil,
             "url" => BitblocksWeb.Endpoint.url() <> "/transactions/#{txid}"
           }
  end

  test "a type with no cheap source reports examples as coming", %{conn: conn} do
    data = conn |> get(~p"/api/v1/types/custom") |> json_response(200) |> Map.fetch!("data")
    assert %{"status" => "coming", "transactions" => []} = data["examples"]
  end

  test "GET /api/v1/types/:id is a 404 for an unknown id", %{conn: conn} do
    assert %{"error" => "Transaction type not found", "id" => "nope"} =
             conn |> get(~p"/api/v1/types/nope") |> json_response(404)
  end
end
