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

  describe "research export (#51)" do
    test "types by 10,000-block bucket, with coverage, provenance and a rows hash", %{conn: conn} do
      typed_block_fixture(0, %{"custom" => 1})
      typed_block_fixture(1, %{"custom" => 2, "p2pkh" => 3})
      Counts.refresh()

      body = conn |> get(~p"/api/v1/types/export") |> json_response(200)

      assert body["dataset"] == "bitblocks-tx-types-by-height"
      assert body["schema_version"] == 1

      assert %{
               "status" => "ok",
               "from_height" => 0,
               "through_height" => 1,
               "bucket_blocks" => 10_000
             } =
               body["coverage"]

      assert body["provenance"]["definitions_sha256"] == TxTypes.definitions_sha256()
      assert body["provenance"]["versions"]["type_counts"] == TxPipeline.version(:type_counts)
      assert body["provenance"]["versions"]["tx_types"] == TxPipeline.version(:tx_types)
      assert is_list(body["provenance"]["runs"])

      assert body["rows"] == [
               %{"type" => "custom", "from_height" => 0, "to_height" => 1, "txs" => 3},
               %{"type" => "p2pkh", "from_height" => 0, "to_height" => 1, "txs" => 3}
             ]

      assert %{"id" => "p2pkh", "txs" => 3, "first_seen_height" => 1, "defined" => true} =
               Enum.find(body["types"], &(&1["id"] == "p2pkh"))

      csv_conn = get(build_conn(), "/api/v1/types/export.csv")
      csv = response(csv_conn, 200)

      assert csv == "type,from_height,to_height,txs\ncustom,0,1,3\np2pkh,0,1,3\n"
      assert [content_type] = get_resp_header(csv_conn, "content-type")
      assert content_type =~ "text/csv"
      assert get_resp_header(csv_conn, "x-through-height") == ["1"]

      sha = :crypto.hash(:sha256, csv) |> Base.encode16(case: :lower)
      assert body["rows_sha256"] == sha
      assert get_resp_header(csv_conn, "x-rows-sha256") == [sha]
    end

    test "before the first refresh, the export is pending with no rows", %{conn: conn} do
      :ets.delete(Counts, :summary)

      body = conn |> get(~p"/api/v1/types/export") |> json_response(200)

      assert body["coverage"]["status"] == "pending"
      assert body["rows"] == []
      assert body["types"] == []
    end
  end
end
