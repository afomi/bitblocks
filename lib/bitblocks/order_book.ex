defmodule Bitblocks.OrderBook do
  @moduledoc """
  Context module for the Open Order Book.

  Provides query functions for active token listings, filtered by
  token, price range, seller, and status.
  Listings are stored as `protocol_instances` with `parsed_data`
  containing the order book operation fields.
  """

  import Ecto.Query, warn: false

  alias Bitblocks.Repo
  alias Bitblocks.ProtocolRegistry
  alias Bitblocks.ProtocolRegistry.Instance

  @pubsub Bitblocks.PubSub
  @topic "order_book"

  @doc """
  Returns active, unspent listings with optional filters.

  ## Options

    * `:token_id` - Filter by BSV-20 token ID
    * `:seller_address` - Filter by seller address
    * `:min_price` - Minimum price per token (string or integer satoshis)
    * `:max_price` - Maximum price per token (string or integer satoshis)
    * `:limit` - Maximum number of results (default 50)
    * `:cursor` - Cursor for pagination (instance ID)
  """
  def list_active_listings(opts \\ []) do
    case get_protocol_id() do
      nil ->
        []

      protocol_id ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        from(i in Instance,
          where: i.protocol_id == ^protocol_id,
          where: i.spent == false,
          where: fragment("?->>'op' = 'list'", i.parsed_data),
          where:
            fragment(
              "(?->>'status' IS NULL OR ?->>'status' = 'active')",
              i.state,
              i.state
            ),
          where:
            fragment(
              "(?->>'expires_at' IS NULL OR ?->>'expires_at' = '' OR ?->>'expires_at' > ?)",
              i.parsed_data,
              i.parsed_data,
              i.parsed_data,
              ^now
            ),
          order_by: [desc: i.inserted_at]
        )
        |> apply_filters(opts)
        |> apply_cursor(opts[:cursor])
        |> limit(^Keyword.get(opts, :limit, 50))
        |> Repo.all()
        |> Enum.map(&instance_to_listing/1)
    end
  end

  @doc """
  Gets a single listing by txid.
  """
  def get_listing(txid) when is_binary(txid) do
    case get_protocol_id() do
      nil ->
        nil

      protocol_id ->
        instance =
          from(i in Instance,
            where: i.protocol_id == ^protocol_id and i.txid == ^txid,
            where: fragment("?->>'op' = 'list'", i.parsed_data),
            limit: 1
          )
          |> Repo.one()

        if instance, do: instance_to_listing(instance), else: nil
    end
  end

  @doc """
  Returns all active listings for a specific token ID.
  """
  def get_listings_for_token(token_id, opts \\ []) do
    list_active_listings(Keyword.put(opts, :token_id, token_id))
  end

  @doc """
  Returns all active listings by a seller address.
  """
  def get_listings_by_seller(seller_address, opts \\ []) do
    list_active_listings(Keyword.put(opts, :seller_address, seller_address))
  end

  @doc """
  Marks a listing as cancelled.

  Sets `spent = true` and `state.status = "cancelled"`.
  """
  def cancel_listing(listing_txid, cancel_txid) when is_binary(listing_txid) do
    case get_listing_instance(listing_txid) do
      nil ->
        {:error, :not_found}

      instance ->
        state = Map.merge(instance.state || %{}, %{"status" => "cancelled"})

        case instance
             |> Instance.changeset(%{spent: true, spent_txid: cancel_txid, state: state})
             |> Repo.update() do
          {:ok, updated} ->
            listing = instance_to_listing(updated)
            broadcast({:listing_cancelled, listing})
            broadcast_token(updated.parsed_data["token_id"], {:listing_cancelled, listing})
            {:ok, listing}

          error ->
            error
        end
    end
  end

  @doc """
  Records a fill (purchase) against a listing.

  Updates `state` with fill details and marks as spent when fully filled.
  """
  def fill_listing(listing_txid, fill_txid, fill_quantity) do
    case get_listing_instance(listing_txid) do
      nil ->
        {:error, :not_found}

      instance ->
        current_state = instance.state || %{}
        current_remaining = parse_quantity(current_state["quantity_remaining"] || instance.parsed_data["quantity"])
        fill_qty = parse_quantity(fill_quantity)
        new_remaining = max(current_remaining - fill_qty, 0)

        fills = Map.get(current_state, "fills", [])
        new_fill = %{"txid" => fill_txid, "quantity" => to_string(fill_qty)}

        fully_filled? = new_remaining == 0

        new_state =
          current_state
          |> Map.put("quantity_remaining", to_string(new_remaining))
          |> Map.put("fills", fills ++ [new_fill])
          |> Map.put("status", if(fully_filled?, do: "filled", else: "partially_filled"))

        attrs = %{state: new_state}
        attrs = if fully_filled?, do: Map.merge(attrs, %{spent: true, spent_txid: fill_txid}), else: attrs

        case instance
             |> Instance.changeset(attrs)
             |> Repo.update() do
          {:ok, updated} ->
            listing = instance_to_listing(updated)
            broadcast({:listing_filled, listing})
            broadcast_token(updated.parsed_data["token_id"], {:listing_filled, listing})
            {:ok, listing}

          error ->
            error
        end
    end
  end

  @doc """
  Indexes a new listing from parsed order book data.

  Creates a protocol_instance and broadcasts the new listing event.
  """
  def index_listing(attrs) when is_map(attrs) do
    case get_protocol_id() do
      nil ->
        {:error, :protocol_not_found}

      protocol_id ->
        instance_attrs = %{
          protocol_id: protocol_id,
          txid: attrs[:txid] || attrs["txid"],
          vout: attrs[:vout] || attrs["vout"] || 0,
          block_height: attrs[:block_height] || attrs["block_height"],
          block_hash: attrs[:block_hash] || attrs["block_hash"],
          parsed_data: attrs[:parsed_data] || attrs["parsed_data"],
          state: %{"status" => "active", "quantity_remaining" => get_in(attrs, [:parsed_data, "quantity"]) || get_in(attrs, ["parsed_data", "quantity"])}
        }

        case ProtocolRegistry.create_instance(instance_attrs) do
          {:ok, instance} ->
            listing = instance_to_listing(instance)
            broadcast({:new_listing, listing})
            token_id = instance.parsed_data["token_id"]
            if token_id, do: broadcast_token(token_id, {:new_listing, listing})
            {:ok, listing}

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  Settles listings whose token UTXO was consumed on-chain.

  Given a list of spend entries `[%{txid: prev_txid, vout: prev_vout,
  spending_txid: settlement_txid}, ...]` (as produced by the spend index),
  finds any active listing whose `token_utxo` equals `"<prev_txid>:<prev_vout>"`
  and marks it fully filled — the settlement transaction consumed the listed
  token UTXO, which by the protocol's implicit-settlement rule *is* the fill
  (see docs/ORDER_BOOK_PROTOCOL.md §"Settlement Flow"). No explicit `fill`
  OP_RETURN is required.

  Idempotent: a listing already `spent` is skipped, so re-processing the same
  block (e.g. a worker retry) does not double-fill.

  Returns the count of listings settled.
  """
  def settle_spent_token_utxos(spend_entries) when is_list(spend_entries) do
    Enum.reduce(spend_entries, 0, fn entry, settled ->
      prev_txid = entry[:txid] || entry["txid"]
      prev_vout = entry[:vout] || entry["vout"]
      settlement_txid = entry[:spending_txid] || entry["spending_txid"]

      with true <- is_binary(prev_txid) and is_integer(prev_vout),
           outpoint = "#{prev_txid}:#{prev_vout}",
           %Instance{} = listing <- get_active_listing_by_token_utxo(outpoint) do
        remaining = listing.state["quantity_remaining"] || listing.parsed_data["quantity"]

        case fill_listing(listing.txid, settlement_txid, remaining) do
          {:ok, _} -> settled + 1
          _ -> settled
        end
      else
        _ -> settled
      end
    end)
  end

  def settle_spent_token_utxos(_), do: 0

  @doc """
  Returns aggregate statistics about the order book.
  """
  def listing_stats do
    case get_protocol_id() do
      nil ->
        %{total_active: 0, total_filled: 0, total_cancelled: 0, unique_tokens: 0}

      protocol_id ->
        active =
          from(i in Instance,
            where: i.protocol_id == ^protocol_id,
            where: i.spent == false,
            where: fragment("?->>'op' = 'list'", i.parsed_data),
            select: count(i.id)
          )
          |> Repo.one()

        filled =
          from(i in Instance,
            where: i.protocol_id == ^protocol_id,
            where: fragment("?->>'op' = 'list'", i.parsed_data),
            where: fragment("?->>'status' = 'filled'", i.state),
            select: count(i.id)
          )
          |> Repo.one()

        cancelled =
          from(i in Instance,
            where: i.protocol_id == ^protocol_id,
            where: fragment("?->>'op' = 'list'", i.parsed_data),
            where: fragment("?->>'status' = 'cancelled'", i.state),
            select: count(i.id)
          )
          |> Repo.one()

        unique_tokens =
          from(i in Instance,
            where: i.protocol_id == ^protocol_id,
            where: i.spent == false,
            where: fragment("?->>'op' = 'list'", i.parsed_data),
            select: fragment("COUNT(DISTINCT ?->>'token_id')", i.parsed_data)
          )
          |> Repo.one()

        %{
          total_active: active || 0,
          total_filled: filled || 0,
          total_cancelled: cancelled || 0,
          unique_tokens: unique_tokens || 0
        }
    end
  end

  @doc """
  Returns a market-data summary for a token, aggregated over confirmed fills.

  A "trade" is a fill recorded against a listing (`state["fills"]`), priced at
  the listing's `price_satoshis`. Volume is denominated in satoshis as
  `sum(fill_quantity * price_satoshis)`.

  The 24h window is measured against the fill record's timestamp — the listing
  instance's `updated_at` (a fill mutates the row, so `updated_at` tracks the
  most recent fill). This is an approximation: a listing filled in multiple
  steps shares one `updated_at`, so all of its fills fall in (or out of) the
  window together. We prefer this over reconstructing per-fill block times,
  which the `fills` records do not carry.

  Returns a map with:

    * `:last_price`          — `price_satoshis` of the most recently updated filled listing
    * `:volume_24h`          — fill volume (satoshis) in the last 24h
    * `:num_trades_24h`      — number of fills in the last 24h
    * `:high_24h`            — highest `price_satoshis` among listings filled in the last 24h
    * `:low_24h`             — lowest `price_satoshis` among listings filled in the last 24h
    * `:total_volume`        — all-time fill volume (satoshis)
    * `:num_trades`          — all-time number of fills
    * `:num_active_listings` — active, unspent listings for the token
    * `:floor_price`         — lowest `price_satoshis` among active listings, or `nil`
  """
  def token_market(token_id) when is_binary(token_id) do
    instances = filled_instances_for_token(token_id)
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-24 * 3600, :second)

    trades = instances_to_trades(instances)
    trades_24h = Enum.filter(trades, &recent?(&1, cutoff))

    last_price =
      case Enum.max_by(instances, & &1.updated_at, NaiveDateTime, fn -> nil end) do
        nil -> nil
        instance -> instance.parsed_data["price_satoshis"]
      end

    active = list_active_listings(token_id: token_id, limit: 1000)

    floor_price =
      active
      |> Enum.map(&to_integer(&1.price_satoshis))
      |> Enum.reject(&(&1 == 0))
      |> case do
        [] -> nil
        prices -> Enum.min(prices)
      end

    %{
      last_price: last_price,
      volume_24h: sum_volume(trades_24h),
      num_trades_24h: length(trades_24h),
      high_24h: price_extreme(trades_24h, &Enum.max/1),
      low_24h: price_extreme(trades_24h, &Enum.min/1),
      total_volume: sum_volume(trades),
      num_trades: length(trades),
      num_active_listings: length(active),
      floor_price: floor_price
    }
  end

  @doc """
  Returns recent confirmed fills (trades) for a token, most recent first.

  Each trade is a flat map:

    * `:txid`            — the fill (purchase/settlement) txid
    * `:listing_txid`    — the listing the fill was recorded against
    * `:token_id`        — the token traded
    * `:quantity`        — fill quantity (integer)
    * `:price_satoshis`  — per-token price (integer)
    * `:total_satoshis`  — `quantity * price_satoshis`
    * `:seller_address`  — the listing's seller
    * `:block_height`    — the listing's block height
    * `:filled_at`       — fill record timestamp (the listing's `updated_at`)

  ## Options

    * `:limit` — maximum number of trades (default 50)
  """
  def token_trades(token_id, opts \\ []) when is_binary(token_id) do
    limit = Keyword.get(opts, :limit, 50)

    token_id
    |> filled_instances_for_token()
    |> instances_to_trades()
    |> Enum.sort_by(& &1.filled_at, {:desc, NaiveDateTime})
    |> Enum.take(limit)
  end

  # -- Private ----------------------------------------------------------------

  defp filled_instances_for_token(token_id) do
    case get_protocol_id() do
      nil ->
        []

      protocol_id ->
        from(i in Instance,
          where: i.protocol_id == ^protocol_id,
          where: fragment("?->>'op' = 'list'", i.parsed_data),
          where: fragment("?->>'token_id' = ?", i.parsed_data, ^token_id),
          where: fragment("?->>'status' IN ('filled', 'partially_filled')", i.state),
          order_by: [desc: i.updated_at]
        )
        |> Repo.all()
    end
  end

  # Flattens each filled instance's `state["fills"]` into individual trade maps,
  # priced at the listing's `price_satoshis`.
  defp instances_to_trades(instances) do
    Enum.flat_map(instances, fn i ->
      pd = i.parsed_data || %{}
      state = i.state || %{}
      price = to_integer(pd["price_satoshis"])

      (state["fills"] || [])
      |> Enum.map(fn fill ->
        qty = to_integer(fill["quantity"])

        %{
          txid: fill["txid"],
          listing_txid: i.txid,
          token_id: pd["token_id"],
          quantity: qty,
          price_satoshis: price,
          total_satoshis: qty * price,
          seller_address: pd["seller_address"],
          block_height: i.block_height,
          filled_at: i.updated_at
        }
      end)
    end)
  end

  defp recent?(%{filled_at: nil}, _cutoff), do: false

  defp recent?(%{filled_at: filled_at}, cutoff) do
    NaiveDateTime.compare(filled_at, cutoff) != :lt
  end

  defp sum_volume(trades) do
    Enum.reduce(trades, 0, fn t, acc -> acc + t.total_satoshis end)
  end

  defp price_extreme([], _fun), do: nil

  defp price_extreme(trades, fun) do
    trades |> Enum.map(& &1.price_satoshis) |> fun.()
  end

  defp get_protocol_id do
    case ProtocolRegistry.get_protocol_by_name("OrderBook") do
      nil -> nil
      protocol -> protocol.id
    end
  end

  defp get_active_listing_by_token_utxo(outpoint) when is_binary(outpoint) do
    case get_protocol_id() do
      nil ->
        nil

      protocol_id ->
        from(i in Instance,
          where: i.protocol_id == ^protocol_id,
          where: i.spent == false,
          where: fragment("?->>'op' = 'list'", i.parsed_data),
          where: fragment("?->>'token_utxo' = ?", i.parsed_data, ^outpoint),
          limit: 1
        )
        |> Repo.one()
    end
  end

  defp get_listing_instance(txid) do
    case get_protocol_id() do
      nil -> nil
      protocol_id ->
        from(i in Instance,
          where: i.protocol_id == ^protocol_id and i.txid == ^txid,
          where: fragment("?->>'op' = 'list'", i.parsed_data),
          limit: 1
        )
        |> Repo.one()
    end
  end

  defp apply_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:token_id, token_id}, q when is_binary(token_id) ->
        from i in q, where: fragment("?->>'token_id' = ?", i.parsed_data, ^token_id)

      {:seller_address, addr}, q when is_binary(addr) ->
        from i in q, where: fragment("?->>'seller_address' = ?", i.parsed_data, ^addr)

      {:min_price, min}, q when not is_nil(min) ->
        min_val = to_integer(min)
        from i in q,
          where: fragment("(NULLIF(?->>'price_satoshis', ''))::bigint >= ?", i.parsed_data, ^min_val)

      {:max_price, max}, q when not is_nil(max) ->
        max_val = to_integer(max)
        from i in q,
          where: fragment("(NULLIF(?->>'price_satoshis', ''))::bigint <= ?", i.parsed_data, ^max_val)

      _, q ->
        q
    end)
  end

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {id, _} -> from(i in query, where: i.id < ^id)
      :error -> query
    end
  end

  defp apply_cursor(query, cursor) when is_integer(cursor) do
    from(i in query, where: i.id < ^cursor)
  end

  defp instance_to_listing(%Instance{} = i) do
    pd = i.parsed_data || %{}
    state = i.state || %{}

    %{
      txid: i.txid,
      vout: i.vout,
      block_height: i.block_height,
      version: pd["version"],
      op: pd["op"],
      token_id: pd["token_id"],
      quantity: pd["quantity"],
      price_satoshis: pd["price_satoshis"],
      seller_address: pd["seller_address"],
      token_utxo: pd["token_utxo"],
      # The seller's pre-signed offer — lets a buyer settle from on-chain data alone.
      seller_pubkey: pd["seller_pubkey"],
      seller_sig: pd["seller_sig"],
      sighash_flag: pd["sighash_flag"],
      expires_at: pd["expires_at"],
      min_quantity: pd["min_quantity"],
      status: state["status"] || "active",
      quantity_remaining: state["quantity_remaining"] || pd["quantity"],
      fills: state["fills"] || [],
      spent: i.spent,
      spent_txid: i.spent_txid,
      inserted_at: i.inserted_at
    }
  end

  defp to_integer(val) when is_integer(val), do: val
  defp to_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end
  defp to_integer(_), do: 0

  defp parse_quantity(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_quantity(val) when is_integer(val), do: val
  defp parse_quantity(_), do: 0

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, event)
  end

  defp broadcast_token(nil, _event), do: :ok

  defp broadcast_token(token_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, "#{@topic}:token:#{token_id}", event)
  end
end
