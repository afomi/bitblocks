defmodule BitblocksWeb.DownloadLiveTest do
  # /downloads/:id (https://github.com/afomi/bitblocks/issues/111): the buyer's
  # page. It waits for Stripe's webhook and updates by itself, then shows the
  # manifest anchored to block hashes, signed links, the resume script, and
  # "Resume"; nobody else can open it.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.DownloadsFixtures

  alias Bitblocks.Downloads.{Purchase, Purchases}
  alias Bitblocks.Repo

  setup do
    with_price()
    with_checkout_configured()
    stub_checkout(self())
    blocks = stored_chain(["zero", "one", "two"])
    user = user!()

    {:ok, p} =
      Purchases.create(user, %{"from" => "0", "to" => "2", "data" => "raw", "format" => "bin"})

    {:ok, _} = Purchases.start_checkout(p, "https://example.test")
    {:ok, user: user, blocks: blocks, purchase: Repo.get!(Purchase, p.id)}
  end

  defp signed_in(conn, user), do: init_test_session(conn, %{"user_id" => user.id})

  defp pay_and_prepare(p) do
    {:ok, "paid"} =
      Purchases.handle_event(event("checkout.session.completed", completed_session(p)))

    {:ok, :ready} = Purchases.prepare(Repo.get!(Purchase, p.id))
  end

  test "waits for payment confirmation, then shows Paid by itself", %{
    conn: conn,
    user: user,
    purchase: p
  } do
    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/downloads/#{p.id}")

    assert has_element?(view, "#download-state", "Waiting for payment confirmation")
    assert has_element?(view, "#download-return-to-checkout")
    refute has_element?(view, "#download-files-table")

    pay_and_prepare(p)

    assert render(view) =~ "Your files are ready"
    assert has_element?(view, "#download-state", "Paid")
    assert has_element?(view, "#download-price", "$10.00")
  end

  test "shows the manifest anchored to block hashes, with links, the script and its sha256s", %{
    conn: conn,
    user: user,
    blocks: blocks,
    purchase: p
  } do
    pay_and_prepare(p)
    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/downloads/#{p.id}")

    for b <- blocks do
      assert has_element?(view, "#download-file-#{b.height}", b.hash)
      assert has_element?(view, "#download-file-#{b.height} a[href*='expires=']")
    end

    sum = Base.encode16(:crypto.hash(:sha256, "one"), case: :lower)
    assert has_element?(view, "#download-file-1", sum)
    assert has_element?(view, "#download-manifest[href='/downloads/#{p.id}/manifest.json']")

    assert has_element?(
             view,
             "#download-manifest-sha256",
             Repo.get!(Purchase, p.id).manifest_sha256
           )

    assert has_element?(view, "#download-script", "links.tsv?from=$next&token=")
    assert has_element?(view, "#download-script", "skipped, so running it again resumes")
  end

  test "Resume signs links again from the block given", %{conn: conn, user: user, purchase: p} do
    pay_and_prepare(p)
    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/downloads/#{p.id}")

    view |> form("#download-resume-form", resume: %{from: "2"}) |> render_submit()

    assert_patch(view, ~p"/downloads/#{p.id}?from=2")
    refute has_element?(view, "#download-file-1")
    assert has_element?(view, "#download-file-2 a[href*='expires=']")
    assert has_element?(view, "#download-first-page")
  end

  test "a refunded purchase shows Refunded and no links", %{conn: conn, user: user, purchase: p} do
    pay_and_prepare(p)
    p = Repo.get!(Purchase, p.id)
    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/downloads/#{p.id}")
    assert has_element?(view, "#download-files-table")

    {:ok, "refunded"} =
      Purchases.handle_event(
        event("charge.refunded", %{"payment_intent" => p.stripe_payment_intent})
      )

    assert has_element?(view, "#download-state", "Refunded")
    refute has_element?(view, "#download-files-table")
    refute has_element?(view, "#download-script")
  end

  test "someone else's download is a 404", %{conn: conn, purchase: p} do
    assert_raise Ecto.NoResultsError, fn ->
      conn |> signed_in(user!()) |> live(~p"/downloads/#{p.id}")
    end
  end

  test "a visitor who isn't signed in is sent to sign in and back", %{conn: conn, purchase: p} do
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/downloads/#{p.id}")
    assert to =~ "/sign-in"
    assert to =~ URI.encode_www_form("/downloads/#{p.id}")
  end
end
