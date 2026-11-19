defmodule Bitblocks.Downloads.Purchases do
  @moduledoc """
  Buying a download of a block range with Stripe Checkout, then fetching it
  and resuming it (https://github.com/afomi/bitblocks/issues/111).

  ## The life of a purchase

    1. `create/3` turns a quote (`Bitblocks.Downloads.quote/4`) into a
       `quoted` row, for a signed-in user. Only what we can serve is sold:
       an exact, priced quote, every block's object in the tx store, at or
       below `complete_through`, and at least Stripe's smallest card payment.
       The price is computed here from stored sizes; nothing from the
       browser reaches it but the range.
    2. `start_checkout/2` creates its one Checkout session (the idempotency
       key is the row's id) and moves it to `checkout_open`.
    3. Only a signed `checkout.session.completed` webhook
       (`handle_event/1`, from `BitblocksWeb.StripeWebhookController`) makes
       it `paid`. The success redirect changes nothing. `paid_at` + 30 days is
       `expires_at`.
    4. Paying queues `prepare/2` (`Bitblocks.Workers.DownloadPrepareWorker`):
       each file's sha256, read once from the store and kept
       (`block_object_digests`), then the manifest's own sha256, and
       `ready_at`.
    5. While it is valid (`downloadable?/1`: paid, prepared, not expired),
       `links/3` signs short-lived URLs (`TxStore.presigned_url/3`, S3 in
       prod) for the files, free, as often as asked. The bytes go from the
       store to the buyer, never through a node.
    6. `charge.refunded` makes it `refunded`; `checkout.session.expired`
       makes an unpaid one `expired`. No links are issued for either.

  Every event is recorded in `stripe_events` by its id first, in the same
  transaction as what it does, so a replay or a second delivery changes
  nothing. Status only moves forward: a refunded purchase is never paid again.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Accounts.User
  alias Bitblocks.Chain.Block
  alias Bitblocks.Downloads
  alias Bitblocks.Downloads.{ObjectDigest, Purchase}
  alias Bitblocks.Payments.Stripe
  alias Bitblocks.Repo
  alias Bitblocks.TxStore
  alias Bitblocks.TxStore.BlockObject

  @valid_days 30
  # Stripe's smallest card charge in USD.
  @min_cents 50
  # A signed link lives this long; a page load or a script batch issues fresh ones.
  @link_ttl_seconds 900
  @batch_files 1_000
  @batch_bytes 512 * 1024 * 1024
  @page_files 5_000
  @query_timeout 15_000

  @type refusal ::
          Downloads.error()
          | :no_price
          | :empty
          | {:not_in_store, pos_integer()}
          | {:below_minimum, pos_integer()}
          | :not_configured
          | :not_signed_in

  @doc "Days a paid purchase's links are issued for."
  def valid_days, do: @valid_days

  @doc "Seconds a signed link is good for."
  def link_ttl_seconds, do: config(:link_ttl_seconds, @link_ttl_seconds)

  @doc "Stripe's smallest card payment, in cents."
  def min_cents, do: @min_cents

  @doc "The PubSub topic a purchase's changes are broadcast on, as `{:purchase, id}`."
  def topic(id), do: "download_purchase:#{id}"

  @doc """
  Whether a quote can be bought online: `:ok` or `{:error, refusal}`.
  The same checks `create/3` makes, for the page to show before a click.
  """
  @spec purchasable(map()) :: :ok | {:error, refusal()}
  def purchasable(%{} = quote) do
    cents = quote.price_usd && to_cents(quote.price_usd)

    cond do
      quote.files == 0 -> {:error, :empty}
      not quote.bytes_exact or is_nil(cents) -> {:error, :no_price}
      quote.not_in_store > 0 -> {:error, {:not_in_store, quote.not_in_store}}
      cents < @min_cents -> {:error, {:below_minimum, cents}}
      true -> :ok
    end
  end

  @doc """
  Quotes `from..to` as `data` in `format` afresh and, when it can be bought,
  stores it as a `quoted` purchase for `user`. Returns `{:ok, purchase}` or
  `{:error, refusal}`.
  """
  @spec create(User.t() | nil, map(), keyword()) :: {:ok, Purchase.t()} | {:error, refusal()}
  def create(user, params, opts \\ [])

  def create(%User{id: user_id}, params, opts) do
    with :ok <- if(Stripe.configured?(), do: :ok, else: {:error, :not_configured}),
         {:ok, quote} <-
           Downloads.quote(params["from"], params["to"], params["data"],
             format: params["format"],
             complete_through:
               Keyword.get_lazy(opts, :complete_through, &Bitblocks.Sync.complete_through/0)
           ),
         :ok <- purchasable(quote) do
      case open_purchase(user_id, quote) do
        %Purchase{} = open -> {:ok, open}
        nil -> insert_quote(user_id, quote)
      end
    end
  end

  def create(_user, _params, _opts), do: {:error, :not_signed_in}

  # The buyer's unpaid purchase of this same quote from the last 23 hours,
  # inside Checkout's 24-hour life and Stripe's idempotency window: a second
  # "Pay" reopens the same session rather than making another.
  defp open_purchase(user_id, quote) do
    since = DateTime.add(now(), -23 * 3_600)

    Repo.one(
      from(p in Purchase,
        where:
          p.user_id == ^user_id and p.status in ["quoted", "checkout_open"] and
            p.from_height == ^quote.from and p.to_height == ^quote.to and
            p.data == ^quote.data and p.format == ^quote.format and
            p.bytes == ^quote.bytes and p.price_cents == ^to_cents(quote.price_usd) and
            p.stripe_mode == ^Stripe.mode() and p.inserted_at > ^since,
        order_by: [desc: p.inserted_at],
        limit: 1
      )
    )
  end

  defp insert_quote(user_id, quote) do
    %Purchase{
      user_id: user_id,
      from_height: quote.from,
      to_height: quote.to,
      data: quote.data,
      format: quote.format,
      complete_through: quote.complete_through,
      files: quote.files,
      bytes: quote.bytes,
      billable_gib: quote.billable_gib,
      price_usd_per_gib: quote.price_usd_per_gib,
      price_cents: to_cents(quote.price_usd),
      currency: "usd",
      status: "quoted",
      stripe_mode: Stripe.mode()
    }
    |> Repo.insert()
  end

  @doc """
  The Checkout URL for a purchase: its open session's, or a new session's.
  `base_url` is our own origin (`BitblocksWeb.Endpoint.url/0`), so the
  success and cancel URLs can only point back at us.

  Returns `{:ok, url}` or `{:error, reason}`.
  """
  @spec start_checkout(Purchase.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def start_checkout(
        %Purchase{status: "checkout_open", stripe_checkout_url: "https://" <> _ = url},
        _
      ),
      do: {:ok, url}

  def start_checkout(%Purchase{status: status} = purchase, base_url)
      when status in ["quoted", "checkout_open"] do
    params = %{
      amount_cents: purchase.price_cents,
      name: product_name(purchase),
      description:
        "#{Downloads.format_number(purchase.files)} files, " <>
          "#{Downloads.format_number(purchase.bytes)} bytes. " <>
          "Links for #{@valid_days} days after payment.",
      success_url: base_url <> "/downloads/" <> purchase.id,
      cancel_url: base_url <> "/pricing?" <> quote_query(purchase) <> "#downloads",
      client_reference_id: purchase.id,
      metadata: %{purchase_id: purchase.id, from: purchase.from_height, to: purchase.to_height}
    }

    with {:ok, %{id: session_id, url: url}} <- Stripe.create_checkout_session(params, purchase.id) do
      purchase
      |> Ecto.Changeset.change(
        status: "checkout_open",
        stripe_session_id: session_id,
        stripe_checkout_url: url
      )
      |> Repo.update()
      |> case do
        {:ok, _} -> {:ok, url}
        {:error, _} = error -> error
      end
    else
      # Stripe keeps a refused request's answer under its idempotency key for
      # a day, so this purchase can't succeed; the next "Pay" makes a new one.
      # A timeout or outage keeps it quoted, and a retry reuses the key.
      {:error, {:stripe_error, status, _, _}} = error when status in 400..499 ->
        update!(purchase, status: "failed", failed_reason: "checkout_refused")
        error

      error ->
        error
    end
  end

  def start_checkout(%Purchase{}, _base_url), do: {:error, :not_open}

  @doc "The product name on the Checkout page and the receipt."
  def product_name(%Purchase{} = p) do
    "Bitblocks download: blocks #{Downloads.format_number(p.from_height)} to " <>
      "#{Downloads.format_number(p.to_height)}, raw block files"
  end

  defp quote_query(p) do
    URI.encode_query(%{
      "from" => p.from_height,
      "to" => p.to_height,
      "data" => p.data,
      "format" => p.format
    })
  end

  @doc "A purchase by id, or nil (also nil for an id that isn't a uuid)."
  @spec get(term()) :: Purchase.t() | nil
  def get(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Purchase, uuid)
      :error -> nil
    end
  end

  def get(_), do: nil

  @doc "A purchase by id, only when it belongs to `user`; nil otherwise."
  @spec get_for_user(term(), User.t() | nil) :: Purchase.t() | nil
  def get_for_user(id, %User{id: user_id}) do
    case get(id) do
      %Purchase{user_id: ^user_id} = p -> p
      _ -> nil
    end
  end

  def get_for_user(_id, _user), do: nil

  @doc """
  Where a purchase stands, for the page: `:awaiting_payment`, `:preparing`,
  `:ready`, `:expired` (paid, past its 30 days), `:refunded`, `:failed`,
  `:checkout_expired` (never paid).
  """
  @spec state(Purchase.t(), DateTime.t()) :: atom()
  def state(%Purchase{} = p, now \\ DateTime.utc_now()) do
    case p.status do
      s when s in ["quoted", "checkout_open"] -> :awaiting_payment
      "expired" -> :checkout_expired
      "refunded" -> :refunded
      "failed" -> :failed
      "paid" -> paid_state(p, now)
    end
  end

  defp paid_state(%Purchase{expires_at: %DateTime{} = expires} = p, now) do
    cond do
      DateTime.compare(expires, now) != :gt -> :expired
      is_nil(p.ready_at) -> :preparing
      true -> :ready
    end
  end

  @doc "True while links can be issued: paid, prepared, and before `expires_at`."
  @spec downloadable?(Purchase.t(), DateTime.t()) :: boolean()
  def downloadable?(%Purchase{} = p, now \\ DateTime.utc_now()), do: state(p, now) == :ready

  # ---------------------------------------------------------------------------
  # Stripe events

  @doc """
  Handles one verified Stripe event, exactly once by its id, through the one
  dispatcher (`Bitblocks.Payments.StripeEvents.handle/1`). Returns
  `{:ok, outcome}` (`"duplicate"` for an id seen before), where outcome
  names what happened: `paid`, `expired`, `refunded`, `ignored`, or why the
  event changed nothing (`unknown_purchase`, `wrong_mode`, `amount_mismatch`, ...).
  """
  @spec handle_event(map()) :: {:ok, String.t()} | {:error, term()}
  defdelegate handle_event(event), to: Bitblocks.Payments.StripeEvents, as: :handle

  @doc """
  Applies a download's event inside the dispatcher's transaction, after its
  id was recorded. Returns `{outcome, purchase | nil}`.
  """
  @spec apply_stripe_event(String.t(), map(), DateTime.t()) :: {String.t(), Purchase.t() | nil}
  def apply_stripe_event(type, object, now), do: apply_event(type, object, now)

  @doc "After the event's transaction commits: tell the page, and prepare a paid download."
  def after_stripe_event(outcome, %Purchase{} = purchase) do
    broadcast(purchase)
    if outcome == "paid", do: enqueue_prepare(purchase)
    :ok
  end

  defp apply_event("checkout.session.completed", session, now) do
    case purchase_for_session(session) do
      nil ->
        {"unknown_purchase", nil}

      %Purchase{status: status} = p when status in ["quoted", "checkout_open", "expired"] ->
        cond do
          session["payment_status"] != "paid" ->
            {"not_paid", nil}

          session["amount_total"] != p.price_cents or session["currency"] != p.currency ->
            Logger.error(
              "Download purchase #{p.id}: Checkout paid #{inspect(session["amount_total"])} " <>
                "#{inspect(session["currency"])}, quoted #{p.price_cents} #{p.currency}"
            )

            {"amount_mismatch", update!(p, status: "failed", failed_reason: "amount_mismatch")}

          true ->
            {"paid",
             update!(p,
               status: "paid",
               paid_at: now,
               expires_at: DateTime.add(now, @valid_days * 86_400),
               stripe_payment_intent: string_or_nil(session["payment_intent"])
             )}
        end

      %Purchase{} ->
        {"no_change", nil}
    end
  end

  defp apply_event("checkout.session.expired", session, _now) do
    case purchase_for_session(session) do
      %Purchase{status: status} = p when status in ["quoted", "checkout_open"] ->
        {"expired", update!(p, status: "expired")}

      nil ->
        {"unknown_purchase", nil}

      _ ->
        {"no_change", nil}
    end
  end

  # Any refund, whole or part, ends the links: we can't take back bytes.
  defp apply_event("charge.refunded", charge, now) do
    case purchase_for_payment_intent(charge["payment_intent"]) do
      %Purchase{status: "paid"} = p ->
        {"refunded", update!(p, status: "refunded", refunded_at: now)}

      nil ->
        {"unknown_purchase", nil}

      _ ->
        {"no_change", nil}
    end
  end

  defp apply_event(_type, _object, _now), do: {"ignored", nil}

  # The session must be the one we made for that purchase: its
  # client_reference_id names the purchase, and its id is the one stored.
  # A purchase with no session stored yet (Stripe answered, but saving the
  # answer failed) takes it now, so a payment is never left unopened.
  defp purchase_for_session(%{"id" => "cs_" <> _ = session_id} = session) do
    with {:ok, id} <- Ecto.UUID.cast(session["client_reference_id"]),
         %Purchase{} = p <-
           Repo.one(from(p in Purchase, where: p.id == ^id, lock: "FOR UPDATE")) do
      case p.stripe_session_id do
        ^session_id -> p
        nil -> update!(p, stripe_session_id: session_id)
        _other -> nil
      end
    else
      _ -> nil
    end
  end

  defp purchase_for_session(_), do: nil

  defp purchase_for_payment_intent("pi_" <> _ = pi) do
    Repo.one(from(p in Purchase, where: p.stripe_payment_intent == ^pi, lock: "FOR UPDATE"))
  end

  defp purchase_for_payment_intent(_), do: nil

  defp update!(purchase, changes),
    do: purchase |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp string_or_nil(s) when is_binary(s), do: s
  defp string_or_nil(_), do: nil

  defp broadcast(%Purchase{id: id} = purchase) do
    Phoenix.PubSub.broadcast(Bitblocks.PubSub, topic(id), {:purchase, purchase})
  end

  defp enqueue_prepare(%Purchase{id: id}) do
    Oban.insert(Bitblocks.Workers.DownloadPrepareWorker.new(%{purchase_id: id}))
  end

  # ---------------------------------------------------------------------------
  # Preparing the files

  @doc """
  Brings a paid purchase's files to ready: every block's object hashed
  (sha256, kept in `block_object_digests`), the range checked against what
  was quoted, and the manifest's sha256 recorded. Bounded: works for at most
  `:run_ms` (default 60 s), then returns `{:continue, hashed}` for the worker
  to come back. `{:ok, :ready}` when done, `{:ok, :not_paid}` for anything
  not paid, `{:error, reason}` on a store failure (the worker retries).

  A range that no longer matches its quote (a block missing from the store,
  or the files or bytes changed) marks the purchase `failed`, for a refund
  by hand; that should not happen below `complete_through`.
  """
  @spec prepare(Purchase.t(), keyword()) ::
          {:ok, :ready | :not_paid} | {:continue, non_neg_integer()} | {:error, term()}
  def prepare(purchase, opts \\ [])

  def prepare(%Purchase{status: "paid", ready_at: nil} = p, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :run_ms, 60_000)

    with :ok <- check_range(p),
         :ok <- hash_missing(p, deadline) do
      hashed = hashed_count(p)

      if hashed < p.files do
        p |> Ecto.Changeset.change(hashed_files: hashed) |> Repo.update!() |> broadcast()
        {:continue, hashed}
      else
        ready =
          update!(p,
            hashed_files: hashed,
            manifest_sha256: manifest_sha256(p),
            ready_at: now()
          )

        broadcast(ready)
        {:ok, :ready}
      end
    else
      {:mismatch, reason} ->
        Logger.error("Download purchase #{p.id} failed preparing: #{reason}")
        p |> update!(status: "failed", failed_reason: reason) |> broadcast()
        {:ok, :not_paid}

      {:error, _} = error ->
        error
    end
  end

  def prepare(%Purchase{status: "paid"}, _opts), do: {:ok, :ready}
  def prepare(%Purchase{}, _opts), do: {:ok, :not_paid}

  defp check_range(p) do
    row =
      Repo.one(
        from(b in Block,
          where: b.height >= ^p.from_height and b.height <= ^p.to_height,
          select: %{
            files: count(b.id),
            bytes: fragment("coalesce(sum(?), 0)::bigint", b.size),
            unstored: fragment("count(*) FILTER (WHERE ? IS NULL)", b.raw_object_stored_at),
            incomplete: fragment("count(*) FILTER (WHERE ? <> 'completed')", b.sync_state)
          }
        ),
        timeout: @query_timeout
      )

    cond do
      row.files != p.files -> {:mismatch, "files_changed"}
      row.bytes != p.bytes -> {:mismatch, "bytes_changed"}
      row.unstored > 0 -> {:mismatch, "not_in_store"}
      row.incomplete > 0 -> {:mismatch, "not_completed"}
      true -> :ok
    end
  end

  defp hash_missing(p, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      :ok
    else
      case unhashed(p, 200) do
        [] ->
          :ok

        blocks ->
          case hash_blocks(blocks) do
            :ok -> hash_missing(p, deadline)
            error -> error
          end
      end
    end
  end

  defp unhashed(p, limit) do
    Repo.all(
      from(b in Block,
        left_join: d in ObjectDigest,
        on: d.block_hash == b.hash,
        where: b.height >= ^p.from_height and b.height <= ^p.to_height and is_nil(d.block_hash),
        order_by: b.height,
        limit: ^limit,
        select: %{height: b.height, hash: b.hash, size: b.size}
      ),
      timeout: @query_timeout
    )
  end

  defp hash_blocks(blocks) do
    now = now()

    results =
      blocks
      |> Task.async_stream(
        fn b ->
          {b, TxStore.object_sha256(BlockObject.key(b.height, b.hash), b.size)}
        end,
        max_concurrency: config(:hash_concurrency, 8),
        timeout: 300_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, r} -> r end)

    rows =
      for {b, {:ok, sha}} <- results,
          do: %{
            block_hash: b.hash,
            height: b.height,
            bytes: b.size,
            sha256: sha,
            inserted_at: now
          }

    Repo.insert_all(ObjectDigest, rows, on_conflict: :nothing, conflict_target: :block_hash)

    case Enum.find(results, &match?({_, {:error, _}}, &1)) do
      nil ->
        :ok

      {b, {:error, reason}} ->
        Logger.warning("Download digest failed for block #{b.height}: #{inspect(reason)}")
        {:error, {:digest_failed, b.height}}
    end
  end

  defp hashed_count(p) do
    Repo.one(
      from(b in Block,
        join: d in ObjectDigest,
        on: d.block_hash == b.hash,
        where: b.height >= ^p.from_height and b.height <= ^p.to_height,
        select: count(b.id)
      ),
      timeout: @query_timeout
    )
  end

  # ---------------------------------------------------------------------------
  # The manifest and the links

  @doc """
  Up to `limit` files of the purchase from height `from` on, in height order:
  `%{name, height, block_hash, merkleroot, bytes, sha256}`.
  """
  @spec files(Purchase.t(), non_neg_integer(), pos_integer()) :: [map()]
  def files(%Purchase{} = p, from, limit) do
    from = max(from, p.from_height)

    Repo.all(
      from(b in Block,
        left_join: d in ObjectDigest,
        on: d.block_hash == b.hash,
        where: b.height >= ^from and b.height <= ^p.to_height,
        order_by: b.height,
        limit: ^limit,
        select: %{
          height: b.height,
          block_hash: b.hash,
          merkleroot: b.merkleroot,
          bytes: b.size,
          sha256: d.sha256
        }
      ),
      timeout: @query_timeout
    )
    |> Enum.map(&Map.put(&1, :name, file_name(&1)))
  end

  @doc "A file's name: `<height>-<block hash>.bin`, as the store names its object."
  def file_name(%{height: h, block_hash: hash}), do: "#{h}-#{String.downcase(hash)}.bin"

  @doc """
  The files from height `from` with a signed link each (`url`), good for
  `link_ttl_seconds/0`: at most #{@batch_files} files or #{div(@batch_bytes, 1024 * 1024)} MiB,
  and always at least one file while any are left. `{:error, :not_downloadable}`
  unless the purchase is valid.
  """
  @spec links(Purchase.t(), non_neg_integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def links(%Purchase{} = p, from, opts \\ []) do
    if downloadable?(p) do
      limit = Keyword.get(opts, :limit, @batch_files)
      max_bytes = Keyword.get(opts, :max_bytes, @batch_bytes)
      ttl = link_ttl_seconds()

      p
      |> files(from, limit)
      |> take_bytes(max_bytes)
      |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
        case TxStore.presigned_url(BlockObject.key(file.height, file.block_hash), ttl, file.name) do
          {:ok, url} -> {:cont, {:ok, [Map.put(file, :url, url) | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, files} -> {:ok, Enum.reverse(files)}
        error -> error
      end
    else
      {:error, :not_downloadable}
    end
  end

  defp take_bytes(files, :infinity), do: files
  defp take_bytes([], _max), do: []

  defp take_bytes([first | rest], max) do
    {taken, _} =
      Enum.reduce_while(rest, {[first], first.bytes}, fn f, {acc, sum} ->
        if sum + f.bytes > max, do: {:halt, {acc, sum}}, else: {:cont, {[f | acc], sum + f.bytes}}
      end)

    Enum.reverse(taken)
  end

  @doc """
  The manifest as a stream of iodata chunks of JSON, the same bytes every
  time for a prepared purchase: the range, and every file with its height,
  block hash, merkleroot, bytes and sha256. Read #{@page_files} files a query.
  """
  @spec manifest_stream(Purchase.t()) :: Enumerable.t()
  def manifest_stream(%Purchase{} = p) do
    head =
      [
        ~s({"purchase":),
        Jason.encode!(p.id),
        ~s(,"from_height":),
        Integer.to_string(p.from_height),
        ~s(,"to_height":),
        Integer.to_string(p.to_height),
        ~s(,"data":),
        Jason.encode!(p.data),
        ~s(,"format":),
        Jason.encode!(p.format),
        ~s(,"file_count":),
        Integer.to_string(p.files),
        ~s(,"bytes":),
        Integer.to_string(p.bytes),
        ~s(,"check":),
        Jason.encode!(
          "Each file's sha256 is of the whole file. " <>
            "Its first 80 bytes, hashed twice with SHA-256 and reversed, are its block_hash."
        ),
        ~s(,"files":[)
      ]

    pages =
      Stream.unfold({p.from_height, true}, fn
        :done ->
          nil

        {from, first?} ->
          case files(p, from, @page_files) do
            [] ->
              nil

            files ->
              chunk =
                files
                |> Enum.with_index()
                |> Enum.map(fn {f, i} ->
                  [if(first? and i == 0, do: "", else: ","), manifest_entry(f)]
                end)

              next = List.last(files).height + 1
              {chunk, if(next > p.to_height, do: :done, else: {next, false})}
          end
      end)

    Stream.concat([[head], pages, [["]}\n"]]])
  end

  defp manifest_entry(f) do
    Jason.encode!(
      Jason.OrderedObject.new(
        name: f.name,
        height: f.height,
        block_hash: f.block_hash,
        merkleroot: f.merkleroot,
        bytes: f.bytes,
        sha256: f.sha256
      )
    )
  end

  @doc "The sha256 (lowercase hex) of the manifest's bytes."
  @spec manifest_sha256(Purchase.t()) :: String.t()
  def manifest_sha256(%Purchase{} = p) do
    p
    |> manifest_stream()
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------

  @doc "A plain sentence for a refusal from `create/3` or `purchasable/1`."
  @spec refusal_message(refusal()) :: String.t()
  def refusal_message(:no_price),
    do:
      "This range has no exact price yet, so it can't be bought online. Write to us with the quote."

  def refusal_message(:empty), do: "There are no blocks in this range."

  def refusal_message({:not_in_store, n}),
    do:
      "#{Downloads.format_number(n)} #{if n == 1, do: "block", else: "blocks"} in this range " <>
        "aren't in our file store yet, so it can't be bought online yet. " <>
        "Write to us with the quote, or choose a range we hold in the store."

  def refusal_message({:below_minimum, _}),
    do:
      "The smallest card payment is #{Downloads.format_usd(Decimal.new(@min_cents) |> Decimal.div(100))}. Choose a larger range."

  def refusal_message(:not_configured),
    do: "Paying online isn't open yet. Write to us with the quote."

  def refusal_message(:not_signed_in), do: "Sign in with GitHub to buy a download."

  def refusal_message(reason)
      when reason in [:invalid_range, :unknown_data, :unknown_format] or
             (is_tuple(reason) and elem(reason, 0) in [:above_complete_through, :coming]),
      do: Downloads.error_message(reason)

  def refusal_message(_other), do: "Checkout couldn't start. Try again shortly."

  @doc "Configured purchase counts by status, for `Release.downloads_checkout_status/0`."
  def counts_by_status do
    Repo.all(from(p in Purchase, group_by: p.status, select: {p.status, count(p.id)}))
    |> Map.new()
  end

  defp to_cents(%Decimal{} = usd),
    do: usd |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp config(key, default) do
    :bitblocks |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
