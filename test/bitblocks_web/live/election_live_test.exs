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

  # The default scenario runs to block 21, past close. The states before
  # close need a lower tip: `election_window_test.exs`.
  describe "the voting window" do
    test "after close it says the block voting closed at", %{conn: conn, s: s} do
      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")

      assert has_element?(view, "#election-window", "Voting closed at block 15.")
      assert has_element?(view, ~s(#election-window[data-state="closed"]))
      assert has_element?(view, "#election-seats", "This election fills 2 seats.")
      assert has_element?(view, "#election-heights", "Ballots count in blocks 12 through 15.")
      assert has_element?(view, "#election-tip", "Our headers reach block 21.")
      assert has_element?(view, "#candidate-alice")
      assert has_element?(view, "#candidate-bob")
      assert has_element?(view, "#candidate-carol")

      body = conn |> get(~p"/api/v1/elections/#{s.election}") |> json_response(200)
      assert body["data"]["state"] == "closed"
      assert body["data"]["tip_height"] == 21
      assert body["data"]["opens_at_height"] == 12
      assert body["data"]["closes_at_height"] == 15
    end
  end

  describe "Did my ballot count?" do
    defp check(conn, s, query) do
      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")
      view |> form("#ballot-lookup", %{"query" => query}) |> render_submit()
      view
    end

    defp answer_text(view) do
      view |> element("#ballot-answer") |> render() |> Floki.parse_fragment!() |> Floki.text()
    end

    defp roll_txid(s), do: s.roll |> String.split(".") |> hd()

    test "a counted ballot says Counted, its block, and links a proof and its header", %{
      conn: conn,
      s: s
    } do
      view = check(conn, s, s.txids.second)
      txid = s.txids.second

      assert has_element?(view, "#answer-#{txid}-headline", "Counted")
      assert answer_text(view) =~ "It is in block 13, inside the voting window"
      assert answer_text(view) =~ "This answer is current to block"

      assert has_element?(
               view,
               ~s(#answer-#{txid}-proof a[href="/api/v1/elections/#{s.election}/ballots/#{txid}"]),
               "Its merkle proof"
             )

      assert has_element?(
               view,
               ~s(#answer-#{txid}-proof a[href="/api/v1/headers/13"]),
               "The header of block 13"
             )
    end

    test "an uppercase txid with spaces around it finds the same ballot", %{conn: conn, s: s} do
      view = check(conn, s, "  " <> String.upcase(s.txids.second) <> " ")

      assert has_element?(view, "#answer-#{s.txids.second}-headline", "Counted")
    end

    test "a key not on the roll says so, with the roll's txid", %{conn: conn, s: s} do
      view = check(conn, s, s.txids.outsider)

      assert has_element?(
               view,
               "#answer-#{s.txids.outsider}-headline",
               "Not counted: this key isn't on the roll."
             )

      assert answer_text(view) =~ "is not a member on the roll."
      assert has_element?(view, ~s(#ballot-answer a[href="/transactions/#{roll_txid(s)}"]))
      assert answer_text(view) =~ roll_txid(s)
      refute has_element?(view, "#answer-#{s.txids.outsider}-proof")
    end

    test "a ballot after close says the block voting closed at", %{conn: conn, s: s} do
      view = check(conn, s, s.txids.late)

      assert has_element?(
               view,
               "#answer-#{s.txids.late}-headline",
               "Not counted: confirmed after block 15."
             )

      assert answer_text(view) =~ "It is in block 16, and voting closed at block 15."
      refute has_element?(view, "#answer-#{s.txids.late}-proof")
    end

    test "a replaced ballot says so and links the later one", %{conn: conn, s: s} do
      view = check(conn, s, s.txids.first)

      assert has_element?(
               view,
               "#answer-#{s.txids.first}-headline",
               "Replaced by a later ballot."
             )

      assert has_element?(
               view,
               ~s(#answer-#{s.txids.first} a[href="/transactions/#{s.txids.second}"])
             )
    end

    test "a txid not in our index waits for a block and says how far the index reaches", %{
      conn: conn,
      s: s
    } do
      unknown = random_hash()
      view = check(conn, s, unknown)

      assert has_element?(view, "#answer-#{unknown}-headline", "Waiting for a block.")

      assert answer_text(view) =~
               "This transaction is not in our index yet; our index reaches block 21."

      refute has_element?(view, ~s(#ballot-answer a[href="/transactions/#{unknown}"]))
    end

    test "a ballot whose block a reorg removed waits for a block", %{conn: conn, s: s} do
      view = check(conn, s, s.txids.orphaned)

      assert has_element?(view, "#answer-#{s.txids.orphaned}-headline", "Waiting for a block.")
      assert answer_text(view) =~ "not on the chain our headers hold"
    end

    test "a stored tx that isn't a ballot says so", %{conn: conn, s: s} do
      txid = txid(s.election_tx)
      view = check(conn, s, txid)

      assert has_element?(view, "#answer-#{txid}-headline", "Not a ballot in this count.")
      assert answer_text(view) =~ "It is in block 10, but it holds no ballot for this election."
    end

    test "an address lists its ballots in chain order and says which counts", %{
      conn: conn,
      s: s
    } do
      view = check(conn, s, s.one.address)

      assert has_element?(view, "#ballot-answer-headline", "Counted")

      ids =
        view
        |> element("#ballot-answer-ballots")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.find("#ballot-answer-ballots > li")
        |> Enum.map(&(Floki.attribute(&1, "id") |> hd()))

      assert ids == [
               "answer-#{s.txids.early}",
               "answer-#{s.txids.first}",
               "answer-#{s.txids.second}"
             ]

      assert has_element?(
               view,
               "#answer-#{s.txids.early}-headline",
               "Not counted: confirmed before voting opened."
             )

      assert has_element?(
               view,
               "#answer-#{s.txids.first}-headline",
               "Replaced by a later ballot."
             )

      assert has_element?(view, "#answer-#{s.txids.second}-headline", "Counted")
      refute answer_text(view) =~ s.txids.outsider
      assert has_element?(view, "#candidate-carol", "Elected")
    end

    test "an address not on the roll says so, with the roll's txid", %{conn: conn, s: s} do
      view = check(conn, s, s.outsider.address)

      assert has_element?(
               view,
               "#ballot-answer-headline",
               "Not counted: this key isn't on the roll."
             )

      assert has_element?(
               view,
               ~s(#ballot-answer-address a[href="/transactions/#{roll_txid(s)}"])
             )

      assert has_element?(view, "#answer-#{s.txids.outsider}")
    end

    test "an address whose ballots all failed says none counts", %{conn: conn, s: s} do
      view = check(conn, s, s.three.address)

      assert has_element?(view, "#ballot-answer-headline", "Not counted.")
      assert has_element?(view, "#answer-#{s.txids.late}")
      assert has_element?(view, "#answer-#{s.txids.orphaned}")
    end

    test "a malformed input says what to enter and marks the field", %{conn: conn, s: s} do
      view = check(conn, s, "not a txid")

      assert has_element?(
               view,
               "#ballot-lookup-error",
               "Enter a ballot's transaction id (64 hexadecimal characters) or your address."
             )

      assert has_element?(view, ~s(#ballot-query[aria-invalid="true"]))
      refute has_element?(view, "#ballot-answer-ballots")
    end

    test "the answer sits in a polite live region, so a screen reader hears it", %{
      conn: conn,
      s: s
    } do
      view = check(conn, s, s.txids.second)

      assert has_element?(view, ~s(#ballot-answer[role="status"][aria-live="polite"]))
      assert has_element?(view, ~s(label[for="ballot-query"]))
    end
  end

  describe "GET /api/v1/elections/:outpoint/ballots/:query" do
    test "a counted ballot carries a proof that climbs to our header's merkle root", %{
      conn: conn,
      s: s
    } do
      txid = s.txids.second

      body =
        conn |> get(~p"/api/v1/elections/#{s.election}/ballots/#{txid}") |> json_response(200)

      ballot = body["data"]["ballot"]
      assert body["data"]["kind"] == "txid"
      assert ballot["status"] == "counted"
      assert ballot["headline"] == "Counted"
      assert ballot["height"] == 13

      proof = ballot["proof"]
      assert proof["block_height"] == 13

      assert Bitblocks.Chain.MerkleProof.climb(txid, proof["index"], proof["siblings"]) ==
               proof["merkleroot"]

      header = conn |> get(~p"/api/v1/headers/13") |> json_response(200)
      assert String.downcase(header["data"]["merkleroot"]) == String.downcase(proof["merkleroot"])
      assert String.downcase(header["data"]["hash"]) == String.downcase(proof["block_hash"])
    end

    test "an address gives its ballots in chain order and which counts", %{conn: conn, s: s} do
      body =
        conn
        |> get(~p"/api/v1/elections/#{s.election}/ballots/#{s.one.address}")
        |> json_response(200)

      assert body["data"]["kind"] == "address"
      assert body["data"]["on_roll"] == true
      assert body["data"]["counting"] == s.txids.second

      assert Enum.map(body["data"]["ballots"], & &1["status"]) == [
               "before_open",
               "replaced",
               "counted"
             ]
    end

    test "a txid not in our index is not_indexed, and a malformed query is a 400", %{
      conn: conn,
      s: s
    } do
      body =
        conn
        |> get(~p"/api/v1/elections/#{s.election}/ballots/#{random_hash()}")
        |> json_response(200)

      assert body["data"]["ballot"]["status"] == "not_indexed"
      assert body["data"]["ballot"]["headline"] == "Waiting for a block."

      assert conn
             |> get(~p"/api/v1/elections/#{s.election}/ballots/nope")
             |> json_response(400)
             |> Map.fetch!("error") =~ "Enter a ballot's transaction id"
    end
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
