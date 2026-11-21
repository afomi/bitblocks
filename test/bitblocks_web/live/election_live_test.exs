defmodule BitblocksWeb.ElectionLiveTest do
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ElectionFixtures

  alias Bitblocks.Elections

  setup do
    %{s: scenario()}
  end

  test "the recount guide stays the static file", %{conn: conn} do
    body = conn |> get("/elections/recount.html") |> response(200)

    assert body =~ "Recount an election yourself"
    refute body =~ "An election is named"
  end

  test "the index names an election by its outpoint and does not cast a vote", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/elections")

    assert html =~ "Elections"
    assert html =~ "Beta"
    assert html =~ "The record format is a draft."
    assert html =~ "Bitblocks reads the chain and does not cast a vote."
    assert has_element?(view, "#election-open", "Election")
    assert has_element?(view, "a", "Recount it yourself")
    assert has_element?(view, ~s(a[href="/elections/recount.html"]))
  end

  test "opens the election the form names", %{conn: conn, s: s} do
    {:ok, view, _html} = live(conn, ~p"/elections")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("#election-open", %{"outpoint" => s.election})
             |> render_submit()

    assert to == "/elections/#{s.election}"
  end

  test "shows the tally and why the outsider ballot was not counted", %{conn: conn, s: s} do
    {:ok, view, html} = live(conn, ~p"/elections/#{s.election}")

    assert html =~ "PBA Board 2026"
    assert html =~ "Beta"
    assert html =~ "The record format is a draft."
    assert html =~ "This count is final."

    assert has_element?(
             view,
             "#ballot-#{s.txids.outsider}",
             "Not counted: this key isn't on the roll."
           )

    assert has_element?(view, "#candidate-carol", "2 votes")
    assert has_element?(view, "#candidate-carol", "Elected")
    assert has_element?(view, "#candidate-bob", "1 vote")
    assert has_element?(view, "#candidate-alice", "0 votes")
    assert has_element?(view, ~s(a[href="/transactions/#{s.txids.outsider}"]))
    assert has_element?(view, "a", "Election transaction")
    assert has_element?(view, "a", "Roll transaction")
    assert has_element?(view, "a", "Recount it yourself")
  end

  test "looking up a member address shows that member's ballot and not the outsider's", %{
    conn: conn,
    s: s
  } do
    {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")

    html =
      view
      |> form("#ballot-lookup", %{"query" => s.one.address})
      |> render_submit()

    assert html =~ s.one.address
    assert html =~ s.txids.second
    assert html =~ "Counted"
    assert html =~ "PBA Board 2026"
    assert has_element?(view, "#candidate-carol", "Elected")
    refute html =~ s.txids.outsider
    refute has_element?(view, "#election-ballots", "on the roll")
  end

  test "an unknown outpoint renders the not-found sentence and does not raise", %{conn: conn} do
    unknown = random_hash() <> ".0"
    {:ok, view, html} = live(conn, ~p"/elections/#{unknown}")

    assert html =~ "No election record at that outpoint in the blocks we hold."
    assert has_element?(view, "#election-error")
    refute has_element?(view, "#election-tally")
  end

  test "GET /api/v1/elections/:outpoint returns the same counted number as count_now", %{
    conn: conn,
    s: s
  } do
    assert {:ok, answer} = Elections.count_now(s.election)

    body = conn |> get(~p"/api/v1/elections/#{s.election}") |> json_response(200)

    assert body["data"]["counted"] == answer.count.counted
    assert body["meta"]["app"] == Bitblocks.Elections.Records.app()
  end
end
