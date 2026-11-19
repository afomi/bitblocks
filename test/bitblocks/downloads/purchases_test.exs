defmodule Bitblocks.Downloads.PurchasesTest do
  # Buying a download of a block range (https://github.com/afomi/bitblocks/issues/111):
  # what can be sold, one Checkout session per quote, only the signed webhook
  # opens it, replays change nothing, a refund closes it, and every file has
  # its sha256 and a signed link. Stripe is a Req.Test stub; nothing leaves.
  # Not async: it stores blocks at fixed heights from 0 and sets env vars.
  use Bitblocks.DataCase, async: false

  import Bitblocks.DownloadsFixtures
  use Oban.Testing, repo: Bitblocks.Repo

  alias Bitblocks.Downloads.{ObjectDigest, Purchase, Purchases}
  alias Bitblocks.Payments.StripeEvent
  alias Bitblocks.Repo

  @bodies ["genesis bytes", "block one bytes", "block two, a little longer"]

  setup do
    with_price()
    with_checkout_configured()
    stub_checkout(self())
    blocks = stored_chain(@bodies)
    {:ok, user: user!(), blocks: blocks}
  end

  defp params(from, to),
    do: %{"from" => "#{from}", "to" => "#{to}", "data" => "raw", "format" => "bin"}

  defp open_purchase(user) do
    {:ok, purchase} = Purchases.create(user, params(0, 2))
    {:ok, _url} = Purchases.start_checkout(purchase, "https://example.test")
    Repo.get!(Purchase, purchase.id)
  end

  defp pay(purchase) do
    {:ok, "paid"} =
      Purchases.handle_event(event("checkout.session.completed", completed_session(purchase)))

    Repo.get!(Purchase, purchase.id)
  end

  describe "create/3" do
    test "stores an exact, priced quote, its price computed from stored sizes", %{user: user} do
      {:ok, p} = Purchases.create(user, params(0, 2))

      assert p.status == "quoted"
      assert p.user_id == user.id
      assert p.files == 3
      assert p.bytes == @bodies |> Enum.map(&byte_size/1) |> Enum.sum()
      assert Decimal.equal?(p.billable_gib, Decimal.new("0.01"))
      # 0.01 GiB x $1,000.00 per GiB
      assert p.price_cents == 1_000
      assert p.stripe_mode == "sandbox"
    end

    test "a second Pay on the same quote reopens the same purchase and session", %{user: user} do
      {:ok, first} = Purchases.create(user, params(0, 2))
      {:ok, url} = Purchases.start_checkout(first, "https://example.test")
      assert_received {:stripe_request, _, _, _}

      {:ok, again} = Purchases.create(user, params(0, 2))
      assert again.id == first.id
      assert {:ok, ^url} = Purchases.start_checkout(again, "https://example.test")
      refute_received {:stripe_request, _, _, _}

      # Another buyer, or another range, is its own purchase.
      {:ok, other} = Purchases.create(user!(), params(0, 2))
      refute other.id == first.id
      {:ok, smaller} = Purchases.create(user, params(0, 1))
      refute smaller.id == first.id
    end

    test "refuses a buyer who isn't signed in" do
      assert Purchases.create(nil, params(0, 2)) == {:error, :not_signed_in}
    end

    test "refuses while Checkout isn't configured", %{user: user} do
      without_checkout()
      assert Purchases.create(user, params(0, 2)) == {:error, :not_configured}
    end

    test "refuses a range with a block not in the file store, with the count", %{user: user} do
      Repo.update_all(from(b in Bitblocks.Chain.Block, where: b.height == 1),
        set: [raw_object_stored_at: nil]
      )

      assert Purchases.create(user, params(0, 2)) == {:error, {:not_in_store, 1}}
      assert Purchases.refusal_message({:not_in_store, 1}) =~ "1 block in this range"
    end

    test "refuses a range with a block of no stored size", %{user: user} do
      Repo.update_all(from(b in Bitblocks.Chain.Block, where: b.height == 2), set: [size: nil])
      assert Purchases.create(user, params(0, 2)) == {:error, :no_price}
    end

    test "refuses above complete_through, naming it", %{user: user} do
      assert Purchases.create(user, params(0, 3)) == {:error, {:above_complete_through, 2}}
    end

    test "refuses a price under Stripe's smallest card payment", %{user: user} do
      with_price("10.00")
      assert {:error, {:below_minimum, 10}} = Purchases.create(user, params(0, 2))
      assert Purchases.refusal_message({:below_minimum, 10}) =~ "$0.50"
    end
  end

  describe "start_checkout/2" do
    test "creates one Checkout session, keyed by the purchase id, for the stored price", %{
      user: user
    } do
      {:ok, p} = Purchases.create(user, params(0, 2))
      {:ok, url} = Purchases.start_checkout(p, "https://example.test")

      assert url == "https://checkout.stripe.com/c/pay/cs_test_downloads"
      assert_received {:stripe_request, "/v1/checkout/sessions", [idempotency_key], form}
      assert idempotency_key == p.id
      assert form["mode"] == "payment"
      assert form["payment_method_types[0]"] == "card"
      assert form["line_items[0][price_data][unit_amount]"] == "1000"
      assert form["line_items[0][price_data][currency]"] == "usd"
      assert form["line_items[0][price_data][product_data][name]"] =~ "blocks 0 to 2"
      assert form["success_url"] == "https://example.test/downloads/#{p.id}"
      assert String.starts_with?(form["cancel_url"], "https://example.test/pricing?")
      assert form["client_reference_id"] == p.id

      p = Repo.get!(Purchase, p.id)
      assert p.status == "checkout_open"
      assert p.stripe_session_id == "cs_test_downloads"

      # Asking again returns the open session; no second request.
      assert {:ok, ^url} = Purchases.start_checkout(p, "https://example.test")
      refute_received {:stripe_request, _, _, _}
    end

    test "a session URL off Stripe's Checkout host is refused, so the browser goes nowhere else",
         %{user: user} do
      Req.Test.stub(Bitblocks.Payments.Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => "cs_test_x", "url" => "https://evil.example/pay"})
      end)

      {:ok, p} = Purchases.create(user, params(0, 2))
      assert Purchases.start_checkout(p, "https://example.test") == {:error, :invalid_response}
      assert Repo.get!(Purchase, p.id).status == "quoted"
    end

    test "a Stripe refusal closes that purchase, so the next Pay starts afresh", %{user: user} do
      Req.Test.stub(Bitblocks.Payments.Stripe, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{"type" => "invalid_request_error", "code" => "parameter_invalid"}
        })
      end)

      {:ok, p} = Purchases.create(user, params(0, 2))

      assert Purchases.start_checkout(p, "https://example.test") ==
               {:error, {:stripe_error, 400, "invalid_request_error", "parameter_invalid"}}

      assert Repo.get!(Purchase, p.id).status == "failed"

      {:ok, again} = Purchases.create(user, params(0, 2))
      refute again.id == p.id
    end

    test "Stripe unreachable keeps the purchase quoted, to retry under the same key", %{
      user: user
    } do
      Req.Test.stub(Bitblocks.Payments.Stripe, &Req.Test.transport_error(&1, :econnrefused))
      {:ok, p} = Purchases.create(user, params(0, 2))

      assert Purchases.start_checkout(p, "https://example.test") == {:error, :stripe_unavailable}
      assert Repo.get!(Purchase, p.id).status == "quoted"
      assert {:ok, again} = Purchases.create(user, params(0, 2))
      assert again.id == p.id
    end
  end

  describe "handle_event/1" do
    test "only checkout.session.completed makes it paid, valid for 30 days", %{user: user} do
      p = open_purchase(user)
      assert Purchases.state(p) == :awaiting_payment
      refute Purchases.downloadable?(p)

      Phoenix.PubSub.subscribe(Bitblocks.PubSub, Purchases.topic(p.id))
      p = pay(p)

      assert p.status == "paid"
      assert p.stripe_payment_intent =~ "pi_"
      assert DateTime.diff(p.expires_at, p.paid_at, :day) == 30
      assert Purchases.state(p) == :preparing
      assert_received {:purchase, %Purchase{status: "paid"}}
      assert_enqueued(worker: Bitblocks.Workers.DownloadPrepareWorker, args: %{purchase_id: p.id})
    end

    test "a replayed or twice-delivered event changes nothing", %{user: user} do
      p = open_purchase(user)
      event = event("checkout.session.completed", completed_session(p))

      assert {:ok, "paid"} = Purchases.handle_event(event)
      paid = Repo.get!(Purchase, p.id)

      # Refunded in between: a late duplicate of the payment must not reopen it.
      refund =
        event("charge.refunded", %{"id" => "ch_1", "payment_intent" => paid.stripe_payment_intent})

      assert {:ok, "refunded"} = Purchases.handle_event(refund)

      assert {:ok, "duplicate"} = Purchases.handle_event(event)
      assert {:ok, "duplicate"} = Purchases.handle_event(refund)

      after_replay = Repo.get!(Purchase, p.id)
      assert after_replay.status == "refunded"
      assert after_replay.paid_at == paid.paid_at
      assert Repo.aggregate(StripeEvent, :count) == 2
    end

    test "a second payment event with a new id doesn't move a refunded purchase", %{user: user} do
      p = open_purchase(user) |> pay()

      {:ok, "refunded"} =
        Purchases.handle_event(
          event("charge.refunded", %{"payment_intent" => p.stripe_payment_intent})
        )

      assert {:ok, "no_change"} =
               Purchases.handle_event(event("checkout.session.completed", completed_session(p)))

      assert Repo.get!(Purchase, p.id).status == "refunded"
    end

    test "a refund leaves no live links", %{user: user} do
      p = open_purchase(user) |> pay()
      {:ok, :ready} = Purchases.prepare(p)
      p = Repo.get!(Purchase, p.id)
      assert {:ok, [_ | _]} = Purchases.links(p, 0)

      {:ok, "refunded"} =
        Purchases.handle_event(
          event("charge.refunded", %{"payment_intent" => p.stripe_payment_intent})
        )

      p = Repo.get!(Purchase, p.id)

      assert Purchases.state(p) == :refunded
      assert Purchases.links(p, 0) == {:error, :not_downloadable}
    end

    test "an expired Checkout session expires an unpaid purchase", %{user: user} do
      p = open_purchase(user)

      {:ok, "expired"} =
        Purchases.handle_event(
          event("checkout.session.expired", completed_session(p, %{"payment_status" => "unpaid"}))
        )

      p = Repo.get!(Purchase, p.id)
      assert p.status == "expired"
      assert Purchases.state(p) == :checkout_expired
    end

    test "a paid amount that differs from the quote fails it and opens nothing", %{user: user} do
      p = open_purchase(user)

      assert {:ok, "amount_mismatch"} =
               Purchases.handle_event(
                 event("checkout.session.completed", completed_session(p, %{"amount_total" => 1}))
               )

      p = Repo.get!(Purchase, p.id)
      assert p.status == "failed"
      refute Purchases.downloadable?(p)
    end

    test "a session that isn't the purchase's own, or another mode's event, changes nothing", %{
      user: user
    } do
      p = open_purchase(user)

      assert {:ok, "unknown_purchase"} =
               Purchases.handle_event(
                 event(
                   "checkout.session.completed",
                   completed_session(p, %{"client_reference_id" => Ecto.UUID.generate()})
                 )
               )

      assert {:ok, "wrong_mode"} =
               Purchases.handle_event(
                 event("checkout.session.completed", completed_session(p), %{"livemode" => true})
               )

      assert {:ok, "ignored"} =
               Purchases.handle_event(event("customer.created", %{"id" => "cus_1"}))

      assert Repo.get!(Purchase, p.id).status == "checkout_open"
    end
  end

  test "a payment for a purchase whose session wasn't saved still opens it", %{user: user} do
    {:ok, p} = Purchases.create(user, params(0, 2))
    session = completed_session(%{p | stripe_session_id: "cs_test_unsaved"})

    assert {:ok, "paid"} = Purchases.handle_event(event("checkout.session.completed", session))
    p = Repo.get!(Purchase, p.id)
    assert p.status == "paid"
    assert p.stripe_session_id == "cs_test_unsaved"

    # Another session naming the same purchase is not ours.
    other = completed_session(%{p | stripe_session_id: "cs_test_other"})

    assert {:ok, "unknown_purchase"} =
             Purchases.handle_event(event("checkout.session.completed", other))
  end

  describe "prepare/2, the manifest and links" do
    test "hashes each file, pins the manifest, and signs a link per file", %{
      user: user,
      blocks: blocks
    } do
      p = open_purchase(user) |> pay()
      assert {:ok, :ready} = Purchases.prepare(p)

      p = Repo.get!(Purchase, p.id)
      assert Purchases.state(p) == :ready
      assert p.hashed_files == 3
      assert Repo.aggregate(ObjectDigest, :count) == 3

      files = Purchases.files(p, 0, 10)

      for {file, {block, body}} <- Enum.zip(files, Enum.zip(blocks, @bodies)) do
        assert file.block_hash == block.hash
        assert file.bytes == byte_size(body)
        assert file.sha256 == Base.encode16(:crypto.hash(:sha256, body), case: :lower)
        assert file.name == "#{block.height}-#{block.hash}.bin"
      end

      manifest = p |> Purchases.manifest_stream() |> Enum.into([]) |> IO.iodata_to_binary()
      decoded = Jason.decode!(manifest)
      assert decoded["file_count"] == 3
      assert Enum.map(decoded["files"], & &1["sha256"]) == Enum.map(files, & &1.sha256)
      assert Enum.map(decoded["files"], & &1["block_hash"]) == Enum.map(blocks, & &1.hash)
      assert p.manifest_sha256 == Base.encode16(:crypto.hash(:sha256, manifest), case: :lower)

      {:ok, links} = Purchases.links(p, 1)
      assert Enum.map(links, & &1.height) == [1, 2]
      assert Enum.all?(links, &(&1.url =~ "expires="))

      # A batch is bounded by bytes, and always holds at least one file.
      {:ok, [one]} = Purchases.links(p, 0, max_bytes: 1)
      assert one.height == 0
    end

    test "the worker queued by the payment prepares it", %{user: user} do
      p = open_purchase(user) |> pay()

      assert :ok = perform_job(Bitblocks.Workers.DownloadPrepareWorker, %{purchase_id: p.id})
      assert Purchases.state(Repo.get!(Purchase, p.id)) == :ready

      assert {:cancel, :no_purchase} =
               perform_job(Bitblocks.Workers.DownloadPrepareWorker, %{
                 purchase_id: Ecto.UUID.generate()
               })
    end

    test "works in bounded runs and carries on", %{user: user} do
      p = open_purchase(user) |> pay()
      assert {:continue, 0} = Purchases.prepare(p, run_ms: -1)
      assert {:ok, :ready} = Purchases.prepare(Repo.get!(Purchase, p.id))
    end

    test "a range that changed since the quote fails rather than serving other files", %{
      user: user
    } do
      p = open_purchase(user) |> pay()
      Repo.update_all(from(b in Bitblocks.Chain.Block, where: b.height == 2), set: [size: 999])

      assert {:ok, :not_paid} = Purchases.prepare(p)
      p = Repo.get!(Purchase, p.id)
      assert p.status == "failed"
      assert p.failed_reason == "bytes_changed"
    end

    test "no links after its 30 days", %{user: user} do
      p = open_purchase(user) |> pay()
      {:ok, :ready} = Purchases.prepare(p)

      p =
        Purchase
        |> Repo.get!(p.id)
        |> Ecto.Changeset.change(
          expires_at: DateTime.add(DateTime.utc_now(), -1) |> DateTime.truncate(:second)
        )
        |> Repo.update!()

      assert Purchases.state(p) == :expired
      assert Purchases.links(p, 0) == {:error, :not_downloadable}
    end
  end

  test "get_for_user/2 returns a purchase only to its buyer", %{user: user} do
    p = purchase!(user)
    assert Purchases.get_for_user(p.id, user).id == p.id
    assert Purchases.get_for_user(p.id, user!()) == nil
    assert Purchases.get_for_user(p.id, nil) == nil
    assert Purchases.get_for_user("not-a-uuid", user) == nil
  end
end
