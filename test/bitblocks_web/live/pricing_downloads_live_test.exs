defmodule BitblocksWeb.PricingDownloadsLiveTest do
  # /pricing#downloads (https://github.com/afomi/bitblocks/issues/111): the free
  # quote. Not async: it stores blocks at fixed heights from 0.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  alias Bitblocks.Downloads
  alias BitblocksWeb.Plugs.RateLimiter.AiCrawlers

  @gib 1_073_741_824

  defp chain(sizes) do
    for {size, height} <- Enum.with_index(sizes) do
      block_fixture(%{height: height, size: size, sync_state: "completed"})
    end
  end

  defp submit_quote(view, params) do
    view
    |> form("#downloads-form", quote: Map.merge(%{"data" => "raw", "format" => "bin"}, params))
    |> render_submit()
  end

  test "shows Bulk downloads with Get a quote, and only raw as available", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pricing")

    assert has_element?(view, "#downloads h2", "Bulk downloads")
    assert has_element?(view, "#downloads-quote-button", "Get a quote")
    refute has_element?(view, "#downloads-data-raw[disabled]")
    assert has_element?(view, "#downloads-data-tx_json[disabled]")
    assert has_element?(view, "#downloads-data-data_pack[disabled]")
    assert has_element?(view, "label[for='downloads-data-tx_json']", "(coming)")
    assert has_element?(view, "label[for='downloads-data-data_pack']", "(coming)")
    assert has_element?(view, "#downloads-format option[value='bin']")
  end

  test "quotes the size in GiB and the file count from stored sizes, with no price", %{
    conn: conn
  } do
    chain([@gib, @gib, div(@gib, 2)])
    block_fixture(%{height: 3, size: 100, sync_state: "header_only"})

    {:ok, view, _html} = live(conn, ~p"/pricing")
    submit_quote(view, %{"from" => "0", "to" => "2"})

    assert has_element?(view, "#downloads-quote-range", "0 to 2")
    assert has_element?(view, "#downloads-quote-files", "3")
    assert has_element?(view, "#downloads-quote-size", "2.50 GiB")
    refute has_element?(view, "#downloads-quote-size", "at least")
    assert has_element?(view, "#downloads-quote-bytes", "2,684,354,560")
    assert has_element?(view, "#downloads-quote-price", "Price on request")
    assert has_element?(view, "#downloads-quote-covers", "0 through")
    refute has_element?(view, "#downloads-quote-missing")

    email = AiCrawlers.contact_email()
    assert has_element?(view, "#downloads-contact[href^='mailto:#{email}']", "Contact us")
    refute render(element(view, "#downloads-quote")) =~ "$"
  end

  test "refuses a range above complete_through, naming that height", %{conn: conn} do
    chain([100, 200])
    block_fixture(%{height: 2, size: 300, sync_state: "header_only"})

    {:ok, view, _html} = live(conn, ~p"/pricing")
    submit_quote(view, %{"from" => "0", "to" => "2"})

    assert has_element?(view, "#downloads-error", "every block whole through 1")
    refute has_element?(view, "#downloads-quote")
  end

  test "reports blocks with no stored size instead of guessing", %{conn: conn} do
    chain([100, nil, 300])

    {:ok, view, _html} = live(conn, ~p"/pricing")
    submit_quote(view, %{"from" => "0", "to" => "2"})

    assert has_element?(view, "#downloads-quote-size", "at least")
    assert has_element?(view, "#downloads-quote-bytes", "400")
    assert has_element?(view, "#downloads-quote-missing", "no stored size")
  end

  test "says a range that isn't two whole numbers in order can't be quoted", %{conn: conn} do
    chain([100])

    {:ok, view, _html} = live(conn, ~p"/pricing")
    submit_quote(view, %{"from" => "5", "to" => "1"})

    assert has_element?(view, "#downloads-error", "two whole numbers")
  end

  test "format_gib/1 never reads a small range as zero, and groups thousands" do
    alias BitblocksWeb.PricingLive

    assert PricingLive.format_gib(0) == "0"
    assert PricingLive.format_gib(1_000) == "< 0.01"
    assert PricingLive.format_gib(div(@gib, 2)) == "0.50"
    assert PricingLive.format_gib(12_000 * @gib) == "12,000.00"
  end

  describe "with a price per GiB" do
    setup do
      previous = Application.get_env(:bitblocks, Downloads)
      Application.put_env(:bitblocks, Downloads, price_usd_per_gib: "1.00")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:bitblocks, Downloads, previous),
          else: Application.delete_env(:bitblocks, Downloads)
      end)
    end

    test "publishes the rate, and shows the price with its arithmetic", %{conn: conn} do
      chain([@gib, @gib, div(@gib, 2)])

      {:ok, view, _html} = live(conn, ~p"/pricing")
      assert has_element?(view, "#downloads-rate", "$1.00 per GiB")

      submit_quote(view, %{"from" => "0", "to" => "2"})

      assert has_element?(view, "#downloads-quote-price", "$2.50")
      assert has_element?(view, "#downloads-quote-arithmetic", "2.50 GiB x $1.00 per GiB = $2.50")

      href = view |> element("#downloads-contact") |> render()
      assert href =~ "Contact us"

      assert href =~
               URI.encode("Price: 2.50 GiB x $1.00 per GiB = $2.50", &URI.char_unreserved?/1)
    end

    test "a range with missing sizes stays at least, with the price on request", %{conn: conn} do
      chain([@gib, nil, @gib])

      {:ok, view, _html} = live(conn, ~p"/pricing")
      submit_quote(view, %{"from" => "0", "to" => "2"})

      assert has_element?(view, "#downloads-quote-size", "at least")
      assert has_element?(view, "#downloads-quote-price", "Price on request")
      assert has_element?(view, "#downloads-quote-price-why", "at least $2.00")
      refute has_element?(view, "#downloads-quote-arithmetic")
    end
  end

  test "the estimate follows the form as it changes, with no click", %{conn: conn} do
    chain([100, 200, 300])

    {:ok, view, _html} = live(conn, ~p"/pricing")

    view
    |> form("#downloads-form", quote: %{"from" => "1", "to" => "2", "data" => "raw"})
    |> render_change()

    assert has_element?(view, "#downloads-quote-range", "1 to 2")
    assert has_element?(view, "#downloads-quote-bytes", "500")
  end

  describe "the per-page quote interval" do
    setup do
      Application.put_env(:bitblocks, :downloads_quote_interval_ms, 300)
      on_exit(fn -> Application.put_env(:bitblocks, :downloads_quote_interval_ms, 0) end)
    end

    test "holds a quote asked inside the interval and runs only the latest at its end", %{
      conn: conn
    } do
      chain([100, 200, 300])

      {:ok, view, _html} = live(conn, ~p"/pricing")
      submit_quote(view, %{"from" => "0", "to" => "0"})
      assert has_element?(view, "#downloads-quote-bytes", "100")

      submit_quote(view, %{"from" => "0", "to" => "1"})
      submit_quote(view, %{"from" => "0", "to" => "2"})
      assert has_element?(view, "#downloads-updating")
      assert has_element?(view, "#downloads-quote-bytes", "100")

      Process.sleep(400)

      refute has_element?(view, "#downloads-updating")
      assert has_element?(view, "#downloads-quote-bytes", "600")
      refute has_element?(view, "#downloads-error")
    end
  end

  describe "choosing a range" do
    setup do
      Downloads.clear_size_bands()
      on_exit(&Downloads.clear_size_bands/0)
    end

    test "named ranges fill the form and quote it, cut off at what we hold", %{conn: conn} do
      chain([100, 200, 300])

      {:ok, view, _html} = live(conn, ~p"/pricing")
      render_async(view)

      assert has_element?(view, "#downloads-preset-first_100k-range", "as far as we hold")
      assert has_element?(view, "#downloads-preset-bsv[disabled]")
      assert has_element?(view, "#downloads-preset-bsv-range", "not held yet")

      view |> element("#downloads-preset-all") |> render_click()

      assert has_element?(view, "#downloads-quote-range", "0 to 2")
      assert has_element?(view, "#downloads-quote-bytes", "600")
      assert has_element?(view, "#downloads-to[value='2']")
    end

    test "shows the size of each band, and quotes a band when chosen", %{conn: conn} do
      chain([@gib, div(@gib, 2), nil])

      {:ok, view, _html} = live(conn, ~p"/pricing")
      render_async(view)

      assert has_element?(view, "#downloads-sizes-table caption", "through block 2")
      assert has_element?(view, "#downloads-band-0", "0 to 2")
      assert has_element?(view, "#downloads-band-0", "at least 1.50 GiB")

      view |> element("#downloads-band-0 button") |> render_click()
      assert has_element?(view, "#downloads-quote-range", "0 to 2")
    end

    test "says so when no block is complete", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pricing")
      render_async(view)

      assert has_element?(view, "#downloads-sizes-empty", "No blocks are complete yet")
    end
  end

  test "explains what a file is, how to check it, and what isn't covered", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pricing")

    assert has_element?(view, "#downloads-notes", "80-byte header")
    assert has_element?(view, "#downloads-notes", "block hash")
    assert has_element?(view, "#downloads-notes", "merkle root")
    assert has_element?(view, "#downloads-notes", "What isn't covered yet")
    assert has_element?(view, "#downloads-api", "/api/v1/downloads/sizes")
  end

  describe "#usage" do
    alias Bitblocks.Usage.Rollup

    defp user! do
      id = System.unique_integer([:positive])
      Bitblocks.Repo.insert!(%Bitblocks.Accounts.User{github_id: id, login: "user#{id}"})
    end

    defp rollup!(kind, id, class, requests, bytes) do
      hour =
        DateTime.utc_now() |> DateTime.truncate(:second) |> Map.merge(%{minute: 0, second: 0})

      Bitblocks.Repo.insert!(%Rollup{
        hour: hour,
        caller_kind: kind,
        caller_id: to_string(id),
        endpoint_class: class,
        requests: requests,
        response_bytes: bytes
      })
    end

    test "asks a visitor to sign in or use the API", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pricing")

      assert has_element?(view, "#usage h2", "What am I using?")
      assert has_element?(view, "#usage", "/api/v1/usage")
      refute has_element?(view, "#usage-own")
    end

    test "shows a signed-in user their own use, and their key's, with no price", %{conn: conn} do
      user = user!()
      {:ok, key, _token} = Bitblocks.ApiKeys.issue_trial(user)
      rollup!("user", user.id, "read", 12, 34_000)
      rollup!("key", key.id, "proof", 7, 2_000_000)
      rollup!("user", user.id + 1_000_000, "read", 999, 1)

      {:ok, view, _html} =
        conn |> init_test_session(%{"user_id" => user.id}) |> live(~p"/pricing")

      assert has_element?(view, "#usage-session", "API reads")
      assert has_element?(view, "#usage-session", "12")
      assert has_element?(view, "#usage-session", "34.0 KB")
      refute has_element?(view, "#usage-session", "999")
      assert has_element?(view, "#usage-key", key.prefix)
      assert has_element?(view, "#usage-key", "Proofs and BEEF")
      assert has_element?(view, "#usage-key", "2.0 MB")
      assert has_element?(view, "#usage", "no API price is set yet")
    end
  end
end
