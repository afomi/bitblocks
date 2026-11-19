defmodule BitblocksWeb.PricingLiveTest do
  use BitblocksWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "prices by consumption, with no unlimited plan", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/pricing")

    assert has_element?(view, "#pricing-free", "600/min")
    assert has_element?(view, "#pricing-consumption", "per request")
    refute html =~ "unlimited"
    refute html =~ "/mo"
  end

  describe "for AI crawlers (#crawlers, where the crawler 402 links)" do
    alias BitblocksWeb.Plugs.RateLimiter.AiCrawlers

    test "gives the crawler budget, the key header and where to ask, with no price", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/pricing")

      budget = BitblocksWeb.PricingLive.crawler_budget()
      assert has_element?(view, "#crawlers-budget", Integer.to_string(budget))

      fetcher_budget = BitblocksWeb.PricingLive.fetcher_budget()
      assert has_element?(view, "#crawlers-fetcher-budget", Integer.to_string(fetcher_budget))
      assert has_element?(view, "#crawlers", "/api/v1/ops/*")
      refute render(element(view, "#crawlers")) =~ "whole API"
      assert has_element?(view, "#crawlers-header", "Authorization: Bearer bbk_")
      assert has_element?(view, "#crawlers", "/api/v1/txs/:txid/raw")

      email = AiCrawlers.contact_email()
      assert has_element?(view, "#crawlers-contact[href^='mailto:#{email}']", email)
      assert has_element?(view, "#crawlers", "data license")
      refute render(element(view, "#crawlers")) =~ "$"
    end

    test "the 402 links to this section" do
      assert AiCrawlers.page_url() == "https://bitblocks.app/pricing#crawlers"
    end

    test "robots.txt points AI crawlers here and still disallows the chain paths" do
      robots = File.read!(Application.app_dir(:bitblocks, "priv/static/robots.txt"))
      assert robots =~ "https://bitblocks.app/pricing#crawlers"

      for path <- ~w(/api/ /blocks /transactions) do
        assert robots =~ "\nDisallow: #{path}\n"
      end
    end
  end

  test "promises no uptime figure or SLA", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/pricing")

    refute html =~ "99.95"
    refute html =~ "SLA"
  end
end
