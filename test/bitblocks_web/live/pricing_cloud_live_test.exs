defmodule BitblocksWeb.PricingCloudLiveTest do
  @moduledoc """
  `/pricing#cloud` (https://github.com/afomi/bitblocks/issues/113) and the
  consulting line (https://github.com/afomi/bitblocks/issues/114): quote
  requests by mail, with no price and no billing.

  Not async: it stores blocks at fixed heights from 0, and the estimate runs
  in a task that reads them through the shared sandbox.
  """
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  @email "enterprise@bitblocks.app"

  defp mail_parts(href) do
    "mailto:" <> rest = href
    [address, query] = String.split(rest, "?", parts: 2)
    {address, URI.decode_query(query)}
  end

  defp request_href(view) do
    [href] =
      view |> render() |> Floki.parse_document!() |> Floki.attribute("#cloud-request", "href")

    href
  end

  describe "cloud services" do
    test "names the three services, each with Request a quote, and no price", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pricing")

      assert has_element?(view, "#cloud h2", "Cloud services")

      for {id, name} <- [
            {"projection", "Managed projections"},
            {"database", "Filtered databases"},
            {"instance", "Dedicated instances"}
          ] do
        assert has_element?(view, "#cloud-service-card-#{id} h3", name)
        assert has_element?(view, "#cloud-choose-#{id}", "Request a quote")
      end

      refute render(element(view, "#cloud")) =~ "$"
      assert has_element?(view, "#cloud-request", "Request a quote")
      assert has_element?(view, "#cloud", "We'll reply with a quote.")
    end

    test "a card's Request a quote chooses its service in the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pricing")

      view |> element("#cloud-choose-database") |> render_click()
      assert has_element?(view, "#cloud-service-database[checked]")

      {@email, %{"subject" => subject}} = mail_parts(request_href(view))
      assert subject == "Cloud services quote: Filtered database"
    end

    test "describes a filter, estimates it over the complete blocks, and mails both", %{
      conn: conn
    } do
      for h <- 0..2, do: block_fixture(%{height: h, sync_state: "completed"})
      for h <- [1, 2], do: transaction_fixture(%{block_height: h, protocols: ["MAP"]})
      transaction_fixture(%{block_height: 2, protocols: ["B"]})

      {:ok, view, _html} = live(conn, ~p"/pricing")
      assert has_element?(view, "#cloud-estimate-none")

      params = %{
        "cloud" => %{
          "service" => "projection",
          "source" => "transactions",
          "from_height" => "0",
          "filter" => %{"protocols" => "MAP"}
        }
      }

      view |> element("#cloud-form") |> render_change(params)
      assert has_element?(view, "#cloud-filter-json", ~s({"protocols":["MAP"]}))

      view |> element("#cloud-form") |> render_submit(params)
      assert render_async(view) =~ "cloud-estimate"
      assert has_element?(view, "#cloud-estimate", "2")
      assert has_element?(view, "#cloud-estimate-covers", "An estimate")

      {@email, %{"body" => body}} = mail_parts(request_href(view))
      assert body =~ ~s({"protocols":["MAP"]})
      assert body =~ "Estimate: 2 transactions in blocks 0 to"

      # A changed filter drops the estimate made for the old one.
      view
      |> element("#cloud-form")
      |> render_change(put_in(params, ["cloud", "filter", "protocols"], "B"))

      refute has_element?(view, "#cloud-estimate")
      {@email, %{"body" => body}} = mail_parts(request_href(view))
      assert body =~ "Estimate: not estimated"
    end

    test "says what's wrong with a filter it can't take", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pricing")

      view
      |> element("#cloud-form")
      |> render_change(%{
        "cloud" => %{"source" => "transactions", "filter" => %{"protocols" => ""}}
      })

      assert has_element?(view, "#cloud-errors", "at least one value")
    end

    test "for the Bitcom command log asks for a namespace, not tags", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pricing")

      view
      |> element("#cloud-form")
      |> render_change(%{"cloud" => %{"source" => "bitcom_commands", "namespace" => ""}})

      assert has_element?(view, "#cloud-namespace")
      refute has_element?(view, "#cloud-filter")
      assert has_element?(view, "#cloud-filter-json", "{}")
    end
  end

  describe "consulting" do
    test "a short line with Contact us, mailing us with the subject set", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/pricing")

      assert has_element?(view, "#consulting h2", "Consulting")
      assert has_element?(view, "#consulting-contact", "Contact us")

      [href] = html |> Floki.parse_document!() |> Floki.attribute("#consulting-contact", "href")
      assert {@email, %{"subject" => "Consulting enquiry"}} = mail_parts(href)
      refute render(element(view, "#consulting")) =~ "$"
    end

    test "stays out of the billing code: no Checkout, plan or key mentions it" do
      billing =
        Path.wildcard("lib/bitblocks/{billing,payments}/**/*.ex") ++
          Path.wildcard("lib/bitblocks/{billing,payments,api_keys}.ex")

      assert billing != []

      for path <- billing, File.regular?(path) do
        refute File.read!(path) =~ ~r/consult/i, "#{path} mentions consulting"
      end
    end
  end
end
