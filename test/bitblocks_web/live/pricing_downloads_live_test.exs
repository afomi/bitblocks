defmodule BitblocksWeb.PricingDownloadsLiveTest do
  # /pricing#downloads (https://github.com/afomi/bitblocks/issues/111): the free
  # quote. Not async: it stores blocks at fixed heights from 0.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

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

    assert has_element?(view, "#downloads-error[role='alert']", "every block whole through 1")
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

  test "gives one quote a second per page", %{conn: conn} do
    chain([100])

    {:ok, view, _html} = live(conn, ~p"/pricing")
    submit_quote(view, %{"from" => "0", "to" => "0"})
    assert has_element?(view, "#downloads-quote")

    submit_quote(view, %{"from" => "0", "to" => "0"})
    assert has_element?(view, "#downloads-error", "One quote a second")
  end
end
