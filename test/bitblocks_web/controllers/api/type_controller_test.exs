defmodule BitblocksWeb.Api.TypeControllerTest do
  # Not async: the type counts are one shared cache (Bitblocks.TxTypes.Counts).
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.TxPipeline
  alias Bitblocks.TxTypes
  alias Bitblocks.TxTypes.Counts

  describe "counts" do
    test "each type carries its tx count and first height, with the range they cover", %{
      conn: conn
    } do
      typed_block_fixture(0, %{"custom" => 1})
      typed_block_fixture(1, %{"custom" => 2, "p2pkh" => 3})
      Counts.refresh()

      body = conn |> get(~p"/api/v1/types") |> json_response(200)

      assert %{
               "status" => "ok",
               "through_height" => 1,
               "complete_through" => 1,
               "tip_height" => 1,
               "version" => version,
               "computed_at" => _,
               "note" => note
             } = body["counts"]

      assert version == TxPipeline.version(:type_counts)
      assert note =~ "blocks 0 to 1"

      by_id = Map.new(body["data"], &{&1["id"], &1["counts"]})
      assert %{"txs" => 3, "first_seen_height" => 0} = by_id["custom"]
      assert %{"txs" => 3, "first_seen_height" => 1} = by_id["p2pkh"]
      assert %{"txs" => 0, "first_seen_height" => nil} = by_id["bsv-21"]
      assert by_id["custom"]["per_10000_blocks"] == [%{"from_height" => 0, "txs" => 3}]

      show = conn |> get(~p"/api/v1/types/custom") |> json_response(200)
      assert %{"txs" => 3, "first_seen_height" => 0} = show["data"]["counts"]
    end

    test "before the first refresh, counts are pending and null", %{conn: conn} do
      :ets.delete(Counts, :summary)

      body = conn |> get(~p"/api/v1/types") |> json_response(200)

      assert body["counts"]["status"] == "pending"
      assert Enum.all?(body["data"], &is_nil(&1["counts"]))
    end
  end

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
