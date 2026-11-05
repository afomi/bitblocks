defmodule BitblocksWeb.Api.AnnotationControllerTest do
  use BitblocksWeb.ConnCase, async: false

  alias Bitblocks.Annotations

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")

  test "create, read, update and delete", %{conn: conn} do
    conn =
      conn
      |> json_conn()
      |> post(
        "/api/v1/annotations",
        Jason.encode!(%{kind: "halving", title: "First halving", height: 210_000})
      )

    assert %{"data" => %{"id" => id, "resolved_height" => 210_000, "resolved_by" => "height"}} =
             json_response(conn, 201)

    assert %{"data" => %{"title" => "First halving"}} =
             build_conn() |> get("/api/v1/annotations/#{id}") |> json_response(200)

    assert %{"count" => 1, "kinds" => kinds} =
             build_conn() |> get("/api/v1/annotations") |> json_response(200)

    assert "fork" in kinds

    assert %{"data" => %{"height" => 420_000, "resolved_height" => 420_000}} =
             build_conn()
             |> json_conn()
             |> patch(
               "/api/v1/annotations/#{id}",
               Jason.encode!(%{annotation: %{height: 420_000}})
             )
             |> json_response(200)

    assert build_conn() |> delete("/api/v1/annotations/#{id}") |> response(204)
    assert build_conn() |> get("/api/v1/annotations/#{id}") |> json_response(404)
  end

  test "filters by height range and kind", %{conn: _conn} do
    {:ok, _} = Annotations.create(%{kind: "fork", title: "a", height: 10})
    {:ok, _} = Annotations.create(%{kind: "note", title: "b", height: 20})
    {:ok, _} = Annotations.create(%{kind: "fork", title: "c", height: 300})

    titles = fn path ->
      build_conn()
      |> get(path)
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.map(& &1["title"])
    end

    assert titles.("/api/v1/annotations?from=0&to=100") == ["a", "b"]
    assert titles.("/api/v1/annotations?kind=fork") == ["a", "c"]
  end

  test "an invalid annotation is a 422 with the errors", %{conn: conn} do
    body =
      conn
      |> json_conn()
      |> post("/api/v1/annotations", Jason.encode!(%{kind: "note", title: "No anchor"}))
      |> json_response(422)

    assert body["errors"]["height"] == ["set a height, a txid or a date"]
  end

  test "a write that isn't JSON is refused (the CSRF guard)", %{conn: conn} do
    conn = post(conn, "/api/v1/annotations", %{kind: "note", title: "x", height: 1})
    assert conn.status == 415
    assert Annotations.list() == []
  end

  describe "with the admin gate on" do
    setup do
      previous = Application.get_env(:bitblocks, :admin_auth)
      Application.put_env(:bitblocks, :admin_auth, enabled: true)
      on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, previous) end)
    end

    test "anonymous callers can neither read nor write", %{conn: conn} do
      assert get(conn, "/api/v1/annotations").status == 401

      assert build_conn()
             |> json_conn()
             |> post("/api/v1/annotations", Jason.encode!(%{kind: "note", title: "x", height: 1}))
             |> Map.get(:status) == 401

      assert Annotations.list() == []
    end

    test "an admin may", %{conn: conn} do
      admin =
        Bitblocks.Repo.insert!(%Bitblocks.Accounts.User{
          github_id: 7_004,
          login: "operator",
          admin: true
        })

      assert conn
             |> init_test_session(%{"user_id" => admin.id})
             |> json_conn()
             |> post("/api/v1/annotations", Jason.encode!(%{kind: "note", title: "x", height: 1}))
             |> Map.get(:status) == 201
    end
  end
end
