defmodule BitblocksWeb.Api.ElectionControllerTest do
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ElectionFixtures

  alias Bitblocks.Elections
  alias Bitblocks.Elections.Records

  setup do
    %{s: scenario()}
  end

  test "returns the live count with no key", %{conn: conn, s: s} do
    assert {:ok, answer} = Elections.count_now(s.election)

    body = conn |> get(~p"/api/v1/elections/#{s.election}") |> json_response(200)
    data = body["data"]

    assert data["counted"] == answer.count.counted
    assert data["name"] == "PBA Board 2026"
    assert data["number_elected"] == 2
    assert data["votes_allowed"] == 2
    assert data["opens_at_height"] == 12
    assert data["closes_at_height"] == 15
    assert data["final"] == true
    assert data["current_to"]["height"] == answer.current_to.height
    assert data["current_to"]["hash"] == answer.current_to.hash
    assert data["election"] == s.election

    carol = Enum.find(data["candidates"], &(&1["id"] == "carol"))
    assert carol["name"] == "Carol"
    assert carol["votes"] == 2
    assert carol["elected"] == true

    outsider = Enum.find(data["ballots"], &(&1["txid"] == s.txids.outsider))
    assert outsider["counted"] == false
    assert outsider["status"] == "not_on_roll"
    assert outsider["signer"] == s.outsider.address
    assert outsider["replaced_by"] == nil

    replaced = Enum.find(data["ballots"], &(&1["txid"] == s.txids.first))
    assert replaced["status"] == "replaced"
    assert replaced["replaced_by"] == s.txids.second

    assert body["meta"]["app"] == Records.app()
    assert is_integer(body["meta"]["complete_through"])
    assert is_integer(body["meta"]["covered_through"])
  end

  test "an invalid outpoint is 400", %{conn: conn} do
    body = conn |> get(~p"/api/v1/elections/nope") |> json_response(400)

    assert body["error"] ==
             "An election is named <txid>.<vout>, lowercase hex and a decimal vout."
  end

  test "an unknown outpoint is 404", %{conn: conn} do
    body = conn |> get("/api/v1/elections/#{random_hash()}.0") |> json_response(404)

    assert body["error"] == "No election record at that outpoint in the blocks we hold."
  end

  test "a record we cannot count is 422", %{conn: conn, s: s} do
    [roll_txid, _vout] = String.split(s.roll, ".")

    body = conn |> get("/api/v1/elections/#{roll_txid}.0") |> json_response(422)

    assert body["error"] =~ "not a record we can count"
  end
end
