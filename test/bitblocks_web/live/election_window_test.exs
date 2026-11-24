defmodule BitblocksWeb.ElectionWindowTest do
  @moduledoc """
  The voting window line on `/elections/:outpoint` (#137) before close, and
  its rounding. Each test builds its own chain to the tip it needs; the
  closed state is in `election_live_test.exs`, on the default scenario.
  """
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ElectionFixtures

  alias BitblocksWeb.ElectionCount

  describe "the voting window, before close" do
    test "before open it says when voting opens, in about how long", %{conn: conn} do
      s = scenario(through: 10)
      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")

      assert has_element?(
               view,
               "#election-window",
               "Voting opens at block 12 (in about 20 minutes)."
             )

      assert has_element?(view, ~s(#election-window[data-state="upcoming"]))
      assert has_element?(view, "#election-seats", "This election fills 2 seats.")
      assert has_element?(view, "#candidate-carol")

      body = conn |> get(~p"/api/v1/elections/#{s.election}") |> json_response(200)
      assert body["data"]["state"] == "upcoming"
      assert body["data"]["tip_height"] == 10
    end

    test "while open it says when voting closes, in about how long", %{conn: conn} do
      s = scenario(through: 13)
      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")

      assert has_element?(
               view,
               "#election-window",
               "Voting closes at block 15 (about 20 minutes)."
             )

      assert has_element?(view, ~s(#election-window[data-state="open"]))

      body = conn |> get(~p"/api/v1/elections/#{s.election}") |> json_response(200)
      assert body["data"]["state"] == "open"
      assert body["data"]["tip_height"] == 13
    end

    test "the block before open is already open: a ballot sent then lands in block 12", %{
      conn: conn
    } do
      s = scenario(through: 11)
      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")

      assert has_element?(
               view,
               "#election-window",
               "Voting closes at block 15 (about 40 minutes)."
             )
    end
  end

  describe "the window's time" do
    test "rounds blocks at 10 minutes each to one readable unit, always about" do
      assert ElectionCount.about(1) == "about 10 minutes"
      assert ElectionCount.about(5) == "about 50 minutes"
      assert ElectionCount.about(6) == "about 1 hour"
      assert ElectionCount.about(9) == "about 2 hours"
      assert ElectionCount.about(18) == "about 3 hours"
      assert ElectionCount.about(143) == "about 24 hours"
      assert ElectionCount.about(144) == "about 1 day"
      assert ElectionCount.about(288) == "about 2 days"
      assert ElectionCount.about(1_000) == "about 7 days"
    end

    test "the state follows the next block against both ends of the window" do
      assert ElectionCount.window_state(10, 12, 15) == "upcoming"
      assert ElectionCount.window_state(11, 12, 15) == "open"
      assert ElectionCount.window_state(14, 12, 15) == "open"
      assert ElectionCount.window_state(15, 12, 15) == "closed"
      assert ElectionCount.window_state(nil, 12, 15) == nil
    end

    test "the sentences for a long window, and one seat" do
      assert ElectionCount.window_sentence(%{
               state: "upcoming",
               tip_height: 100,
               opens_at_height: 388,
               closes_at_height: 1_000
             }) == "Voting opens at block 388 (in about 2 days)."

      assert ElectionCount.window_sentence(%{
               state: "open",
               tip_height: 400,
               opens_at_height: 388,
               closes_at_height: 418
             }) == "Voting closes at block 418 (about 3 hours)."

      assert ElectionCount.window_sentence(%{state: nil}) == nil
      assert ElectionCount.seats_label(1) == "1 seat"
    end
  end
end
