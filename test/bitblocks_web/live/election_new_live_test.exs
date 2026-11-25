defmodule BitblocksWeb.ElectionNewLiveTest do
  @moduledoc """
  `/elections/new` (https://github.com/afomi/bitblocks/issues/136, steps 1
  and 2): the form with today's tip, about a week in heights, the count's
  rules beside each field, and the roll and election records as they'll be
  published, each with "Sign in your wallet". The admin gate is off in the
  suite; `user_auth_test.exs` checks it.
  """
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures
  import Bitblocks.ElectionFixtures, only: [key: 0]

  alias Bitblocks.Elections.Compose

  @tip 975_000

  setup do
    block_fixture(%{height: @tip})
    members = for _ <- 1..3, do: key().address
    %{members: members}
  end

  defp pba(members, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "PBA Board 2026",
        "number_elected" => "3",
        "votes_allowed" => "",
        "candidates" => "Ada Okafor\nBea Lindqvist\nChen Wei\nDara Byrne\nEli Moreau",
        "members" => Enum.join(members, "\n"),
        "opens_at_height" => "975007",
        "closes_at_height" => "976014"
      },
      overrides
    )
  end

  test "step 1: a form for the title, seats, candidates and window, with today's tip", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/elections/new")

    assert html =~ "New election"
    assert has_element?(view, "#election-tip", "Today's tip is block 975,000")

    for {id, label} <- [
          {"election_name", "Title"},
          {"election_number_elected", "Seats"},
          {"election_votes_allowed", "Votes per member"},
          {"election_candidates", "Candidates"},
          {"election_members", "Roll"},
          {"election_opens_at_height", "Opens at block"},
          {"election_closes_at_height", "Closes at block"}
        ] do
      assert has_element?(view, ~s(label[for="#{id}"]), label)
      assert has_element?(view, "##{id}")
    end

    assert html =~ "never signs or sends a transaction"
  end

  test "about a week turns into heights, and says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/elections/new")

    assert has_element?(view, "#election-week-hint", "Opens at block 975,007")
    assert has_element?(view, "#election-week-hint", "1,008")
    assert has_element?(view, "#election-week-hint", "976,014")

    view |> element("#election-week") |> render_click()

    assert has_element?(view, ~s(#election_opens_at_height[value="975007"]))
    assert has_element?(view, ~s(#election_closes_at_height[value="976014"]))
    assert has_element?(view, "#election-window", "1,008")
    assert has_element?(view, "#election-window", "about 7 days")
  end

  test "step 2: the roll and the election as they'll be published, and Sign in your wallet", %{
    conn: conn,
    members: members
  } do
    {:ok, view, _html} = live(conn, ~p"/elections/new")

    view |> form("#election-form", election: pba(members)) |> render_submit()

    roll = Compose.roll(members)

    # 1. The roll, as a B:// file, with its sha256.
    assert has_element?(view, "#record-roll-heading", "1. The roll")
    assert has_element?(view, "#record-roll-sha256", roll.sha256)
    assert has_element?(view, "#record-roll-script", roll.script_hex)
    assert has_element?(view, "#record-roll-message", roll.message_hex)
    assert has_element?(view, "#record-roll-sign", "Sign in your wallet")
    assert has_element?(view, "#record-roll-aip", "fields 1 to #{length(roll.pushes)}")
    assert render(view) =~ "&quot;lockingScript&quot;: &quot;#{roll.script_hex}&quot;"

    # 2. The election, a template until the roll's outpoint is in.
    assert has_element?(view, "#record-election-heading", "2. The election")

    assert has_element?(
             view,
             "#record-election-roll-pending",
             "fills in once the roll is broadcast"
           )

    assert has_element?(view, "#record-election-fields", roll.sha256)
    assert has_element?(view, "#record-election-waiting")
    refute has_element?(view, "#record-election-sign")

    txid = String.duplicate("cd", 32)
    view |> form("#election-roll-form", roll_outpoint: txid) |> render_change()

    refute has_element?(view, "#record-election-roll-pending")
    assert has_element?(view, "#record-election-fields", "#{txid}.0")
    assert has_element?(view, "#record-election-sign", "Sign in your wallet")
    assert has_element?(view, "#record-election-create-action", "Publish the election")
  end

  test "a roll outpoint that isn't one says so beside the field", %{conn: conn, members: members} do
    {:ok, view, _html} = live(conn, ~p"/elections/new")
    view |> form("#election-form", election: pba(members)) |> render_submit()

    view |> form("#election-roll-form", roll_outpoint: "not-a-txid") |> render_change()

    assert has_element?(
             view,
             "#election-roll-outpoint-error",
             "Enter the roll's outpoint as <txid>.<vout>."
           )

    assert has_element?(view, ~s(#election-roll-outpoint[aria-invalid="true"]))
    refute has_element?(view, "#record-election-sign")
  end

  test "the count's rules are plain words next to each field, and no record is shown", %{
    conn: conn,
    members: members
  } do
    {:ok, view, _html} = live(conn, ~p"/elections/new")

    view
    |> form("#election-form",
      election:
        pba(members, %{
          "number_elected" => "0",
          "candidates" => "ada: Ada\nada: Ada again",
          "opens_at_height" => "975001"
        })
    )
    |> render_submit()

    assert has_element?(view, "#number_elected-error", "Seats must be 1 or more.")
    assert has_element?(view, "#candidates-error", "Two candidates have the same id")
    assert has_element?(view, "#opens_at_height-error", "Voting must open after block 975001")
    assert has_element?(view, ~s(#election_number_elected[aria-invalid="true"]))

    assert has_element?(
             view,
             ~s(#election_number_elected[aria-describedby="number_elected-error"])
           )

    refute has_element?(view, "#election-records")
  end
end
