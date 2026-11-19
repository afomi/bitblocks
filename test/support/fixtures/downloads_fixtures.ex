defmodule Bitblocks.DownloadsFixtures do
  @moduledoc """
  Paid downloads in tests (https://github.com/afomi/bitblocks/issues/111):
  completed blocks whose objects are in the local tx store, a buyer, a
  purchase at any status, Checkout configured through the environment, and
  signed Stripe events. No Stripe call is ever made: config/test.exs points
  `Bitblocks.Payments.Stripe` at the `Req.Test` stub of the same name.
  """

  import Bitblocks.ChainFixtures
  import Ecto.Query, only: [from: 2]

  alias Bitblocks.Chain.Block
  alias Bitblocks.Downloads.Purchase
  alias Bitblocks.Payments.Stripe
  alias Bitblocks.Repo
  alias Bitblocks.TxStore.BlockObject

  @webhook_secret "whsec_test_downloads"
  @envs ["STRIPE_SANDBOX_SECRET_KEY", "STRIPE_SANDBOX_WEBHOOK_SECRET"]

  def webhook_secret, do: @webhook_secret

  @doc """
  Blocks 0.. as completed rows, one per entry of `bodies` (binaries), each
  object written to the local store and stamped `raw_object_stored_at`.
  Returns the blocks.
  """
  def stored_chain(bodies) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {bytes, height} <- Enum.with_index(bodies) do
      hash = Base.encode16(:crypto.hash(:sha256, "block #{height} #{bytes}"), case: :lower)

      block =
        block_fixture(%{
          height: height,
          hash: hash,
          size: byte_size(bytes),
          sync_state: "completed"
        })

      :ok = Bitblocks.TxStore.Local.put(BlockObject.key(height, hash), bytes)

      {1, _} =
        Repo.update_all(from(b in Block, where: b.id == ^block.id),
          set: [raw_object_stored_at: now]
        )

      %{block | raw_object_stored_at: now}
    end
  end

  def user! do
    id = System.unique_integer([:positive])
    Repo.insert!(%Bitblocks.Accounts.User{github_id: id, login: "buyer#{id}"})
  end

  @doc "Sets a price per GiB for the test, restored on exit."
  def with_price(price \\ "1000.00") do
    previous = Application.get_env(:bitblocks, Bitblocks.Downloads)
    Application.put_env(:bitblocks, Bitblocks.Downloads, price_usd_per_gib: price)
    Bitblocks.Downloads.clear_size_bands()

    ExUnit.Callbacks.on_exit(fn ->
      Bitblocks.Downloads.clear_size_bands()

      if previous,
        do: Application.put_env(:bitblocks, Bitblocks.Downloads, previous),
        else: Application.delete_env(:bitblocks, Bitblocks.Downloads)
    end)
  end

  @doc "Sets the sandbox key and webhook secret, as Ryan would; removed on exit."
  def with_checkout_configured do
    previous = Map.new(@envs, &{&1, System.get_env(&1)})
    System.put_env("STRIPE_SANDBOX_SECRET_KEY", "rk_test_downloads")
    System.put_env("STRIPE_SANDBOX_WEBHOOK_SECRET", @webhook_secret)
    ExUnit.Callbacks.on_exit(fn -> restore(previous) end)
  end

  @doc "Removes the Checkout variables for the test; restored on exit."
  def without_checkout do
    previous = Map.new(@envs, &{&1, System.get_env(&1)})
    Enum.each(@envs, &System.delete_env/1)
    ExUnit.Callbacks.on_exit(fn -> restore(previous) end)
  end

  defp restore(previous) do
    for {k, v} <- previous do
      if v, do: System.put_env(k, v), else: System.delete_env(k)
    end
  end

  @doc "A purchase row with these fields, over blocks `from..to` already stored."
  def purchase!(user, attrs \\ %{}) do
    struct(
      %Purchase{
        user_id: user.id,
        from_height: 0,
        to_height: 0,
        data: "raw",
        format: "bin",
        complete_through: 0,
        files: 1,
        bytes: 0,
        billable_gib: Decimal.new("0.01"),
        price_usd_per_gib: Decimal.new("1000.00"),
        price_cents: 1_000_00,
        status: "quoted",
        stripe_mode: "sandbox"
      },
      attrs
    )
    |> Repo.insert!()
  end

  @doc """
  A paid, prepared purchase over `blocks` (already stored rows), each with a
  digest, valid for 30 days: what `/downloads/:id` shows once ready.
  """
  def ready_purchase!(user, blocks) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      Bitblocks.Downloads.ObjectDigest,
      for b <- blocks do
        %{
          block_hash: b.hash,
          height: b.height,
          bytes: b.size || 0,
          sha256: Base.encode16(:crypto.hash(:sha256, b.hash), case: :lower),
          inserted_at: now
        }
      end,
      on_conflict: :nothing
    )

    heights = Enum.map(blocks, & &1.height)

    purchase!(user, %{
      from_height: Enum.min(heights),
      to_height: Enum.max(heights),
      complete_through: Enum.max(heights),
      files: length(blocks),
      bytes: blocks |> Enum.map(&(&1.size || 0)) |> Enum.sum(),
      status: "paid",
      stripe_session_id: "cs_test_" <> Integer.to_string(System.unique_integer([:positive])),
      paid_at: now,
      expires_at: DateTime.add(now, 30 * 86_400),
      hashed_files: length(blocks),
      ready_at: now,
      manifest_sha256: String.duplicate("ab", 32)
    })
  end

  @doc """
  The value of a session cookie signed in as `user`, for a browser test:
  set it with `Wallaby.Browser.set_cookie/3` under `session_cookie_key/0`.
  """
  def session_cookie(user) do
    opts =
      Plug.Session.init(
        store: :cookie,
        key: session_cookie_key(),
        signing_salt: "+2ADwU4P",
        same_site: "Lax"
      )

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:secret_key_base, BitblocksWeb.Endpoint.config(:secret_key_base))
      |> Plug.Session.call(opts)
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_session("user_id", user.id)
      |> Plug.Conn.send_resp(200, "")

    conn.resp_cookies[session_cookie_key()].value
  end

  def session_cookie_key, do: "_bitblocks_key"

  @doc "A Stripe event map, as the webhook decodes one."
  def event(type, object, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "evt_" <> Integer.to_string(System.unique_integer([:positive])),
        "object" => "event",
        "type" => type,
        "livemode" => false,
        "data" => %{"object" => object}
      },
      attrs
    )
  end

  @doc "The checkout.session.completed object for a purchase with an open session."
  def completed_session(%Purchase{} = p, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => p.stripe_session_id,
        "object" => "checkout.session",
        "client_reference_id" => p.id,
        "payment_status" => "paid",
        "amount_total" => p.price_cents,
        "currency" => "usd",
        "payment_intent" => "pi_" <> String.replace(p.id, "-", "")
      },
      attrs
    )
  end

  @doc "A raw body and its Stripe-Signature header, signed now."
  def signed(event, secret \\ @webhook_secret) do
    body = Jason.encode!(event)
    {body, Stripe.sign(body, secret, System.system_time(:second))}
  end

  @doc "Stubs Checkout session creation; sends each request to the test process."
  def stub_checkout(test_pid, session_id \\ "cs_test_downloads") do
    Req.Test.stub(Stripe, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:stripe_request, conn.request_path, Plug.Conn.get_req_header(conn, "idempotency-key"),
         URI.decode_query(body)}
      )

      Req.Test.json(conn, %{
        "id" => session_id,
        "object" => "checkout.session",
        "url" => "https://checkout.stripe.com/c/pay/" <> session_id
      })
    end)
  end
end
