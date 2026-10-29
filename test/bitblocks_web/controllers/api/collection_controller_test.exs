defmodule BitblocksWeb.Api.CollectionControllerTest do
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.OrdinalFixtures

  alias Bitblocks.OrdinalCollections

  # Endpoints take a slug or a collection id; tests use an ad-hoc collection
  # id, so they pass it as the id. Known slugs are covered in resolve tests.
  setup do
    collection_txid = tx([funding_outpoint()], [contract("collection")]) |> publish(839_715)
    cid = "#{collection_txid}_0"
    minter = address()
    mint = tx([cid], [contract(), item(cid, "Tardinian 1", minter)]) |> publish(839_716)

    OrdinalCollections.sync(cid, [mint], follow: false)
    %{cid: cid, minter: minter, origin: "#{mint}_1"}
  end

  defp get_json(path, status \\ 200), do: build_conn() |> get(path) |> json_response(status)

  test "GET /api/v1/collections/:id/items lists items with traits", ctx do
    body = get_json("/api/v1/collections/#{ctx.cid}/items")

    assert [%{"origin" => origin, "name" => "Tardinian 1", "traits" => [trait]}] = body["data"]
    assert origin == ctx.origin
    assert trait == %{"name" => "Eyes", "value" => "Reptilian", "description" => "Reptilian!"}
    assert body["meta"]["next_cursor"] == nil
  end

  test "GET …/items/:outpoint answers membership; ownership needs a trace", ctx do
    data = get_json("/api/v1/collections/#{ctx.cid}/items/#{ctx.origin}")["data"]

    assert data["member"] == true
    assert data["trace_state"] == "untraced"
    # Not traced yet, so whether this outpoint is spent is unknown, not false.
    assert data["spent"] == nil
  end

  test "?refresh=1 traces first; dotted outpoints are accepted", ctx do
    [txid, vout] = String.split(ctx.origin, "_")
    data = get_json("/api/v1/collections/#{ctx.cid}/items/#{txid}.#{vout}?refresh=1")["data"]

    assert data["trace_state"] == "current"
    assert data["owner"] == ctx.minter
    assert data["spent"] == false
    assert data["trace_source"] == "whatsonchain"
  end

  test "a moved item: its origin is spent, and the current outpoint is reported", ctx do
    buyer = address()
    transfer = tx([ctx.origin], [p2pkh(buyer, 1)]) |> publish()
    spend(ctx.origin, transfer, 0)

    data = get_json("/api/v1/collections/#{ctx.cid}/items/#{ctx.origin}?refresh=1")["data"]

    assert data["spent"] == true
    assert data["current_outpoint"] == "#{transfer}_0"
    assert data["owner"] == buyer
  end

  test "unknown outpoints are a 404 with member unknown; unknown collections a 404", ctx do
    body = get_json("/api/v1/collections/#{ctx.cid}/items/#{String.duplicate("a", 64)}_0", 404)
    assert body["member"] == "unknown"

    assert get_json("/api/v1/collections/nope/items", 404)
  end

  test "GET /api/v1/collections/:id summarizes, with a pinnable list hash and basis", ctx do
    data = get_json("/api/v1/collections/#{ctx.cid}")["data"]

    assert %{"items" => 1, "trace_states" => %{"untraced" => 1}} = data

    expected_hash =
      :crypto.hash(:sha256, ctx.origin) |> Base.encode16(case: :lower)

    assert data["verification"]["list_hash"] == expected_hash
    assert data["verification"]["by"] == "bitblocks"
    assert data["verification"]["basis"] == "mint_contract_chain"
    assert data["verification"]["verified_through_height"] == 839_716
  end

  test "items carry who verified membership and on what basis", ctx do
    data = get_json("/api/v1/collections/#{ctx.cid}/items/#{ctx.origin}")["data"]

    assert %{
             "verified" => true,
             "by" => "bitblocks",
             "basis" => "mint_contract_chain",
             "chain_from" => cid,
             "claim" => "MAP subTypeData.collectionId"
           } = data["membership"]

    assert cid == ctx.cid
  end

  describe "POST /api/v1/collections/:id/items/lookup" do
    test "answers each outpoint in order, unknown ones as member unknown", ctx do
      [txid, vout] = String.split(ctx.origin, "_")
      stranger = "#{String.duplicate("b", 64)}_0"

      data =
        build_conn()
        |> post("/api/v1/collections/#{ctx.cid}/items/lookup", %{
          outpoints: [stranger, "#{txid}.#{vout}"]
        })
        |> json_response(200)
        |> Map.get("data")

      assert [%{"outpoint" => ^stranger, "member" => "unknown"}, found] = data
      assert found["member"] == true
      assert found["name"] == "Tardinian 1"
      assert found["outpoint"] == ctx.origin
    end

    test "rejects a missing list and more than 200 outpoints", ctx do
      path = "/api/v1/collections/#{ctx.cid}/items/lookup"

      assert build_conn() |> post(path, %{}) |> json_response(400)

      too_many = for n <- 1..201, do: "#{String.duplicate("c", 64)}_#{n}"
      assert build_conn() |> post(path, %{outpoints: too_many}) |> json_response(400)
    end
  end
end
