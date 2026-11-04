defmodule BitblocksWeb.Api.StatusControllerTest do
  # GET /api/v1/status: how healthy and how current Bitblocks is, public and
  # cheap (cached state only), never the node's address.
  use BitblocksWeb.ConnCase, async: false

  test "answers health as JSON", %{conn: conn} do
    body = conn |> get("/api/v1/status") |> json_response(200)

    assert body["status"] in ["ok", "degraded", "down"]
    assert Map.has_key?(body, "index")
    assert Map.has_key?(body["index"], "complete_through")
    assert Map.has_key?(body, "node")
    assert Map.has_key?(body, "lag")
    refute Jason.encode!(body) =~ "8332"
  end

  test "names the running release", %{conn: conn} do
    body = conn |> get("/api/v1/status") |> json_response(200)
    assert Map.has_key?(body["release"], "sha")
  end

  test "coverage answers a curve", %{conn: conn} do
    :persistent_term.erase({Bitblocks.Ops, :coverage})
    body = conn |> get("/api/v1/status/coverage") |> json_response(200)
    assert body["bucket_size"] == 10_000
    assert is_list(body["buckets"])
    assert Map.has_key?(body, "eta_hours")
  end

  test "derivations answer each step's version, the stage versions and the latest runs",
       %{conn: conn} do
    alias Bitblocks.Chain.TxPipeline

    Bitblocks.Repo.insert!(%Bitblocks.Derivations.Run{
      derivation: "tallies",
      version: TxPipeline.version(:tallies),
      from_height: 0,
      to_height: 10,
      applied: false,
      outcome: "failed",
      error: "connect to http://10.0.0.5:8332 refused\nstack",
      started_at: DateTime.utc_now()
    })

    body = conn |> get("/api/v1/status/derivations") |> json_response(200)

    assert Enum.map(body["steps"], & &1["name"]) == Enum.map(TxPipeline.steps(), & &1.name())

    assert %{"name" => "sats_in", "stage" => "chunk", "version" => 1} =
             Enum.find(body["steps"], &(&1["name"] == "sats_in"))

    assert body["stages"] == %{
             "chunk" => TxPipeline.version(:chunk),
             "tx" => TxPipeline.version(:tx),
             "block" => TxPipeline.version(:block)
           }

    assert %{"version" => v, "stamp" => "transactions.tallies_version"} =
             Enum.find(body["derivations"], &(&1["name"] == "tallies"))

    assert v == TxPipeline.version(:tallies)

    assert [%{"derivation" => "tallies", "outcome" => "failed", "error" => error} | _] =
             body["runs"]

    assert error == "connect to [url] refused"
    refute Jason.encode!(body) =~ "8332"
    refute Jason.encode!(body) =~ "10.0.0.5"
  end
end
