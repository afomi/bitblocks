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

  # -- Private ----------------------------------------------------------------

  defp get_protocol_id do
    case ProtocolRegistry.get_protocol_by_name("OrderBook") do
      nil -> nil
      protocol -> protocol.id
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
      op: pd["op"],
      token_id: pd["token_id"],
      quantity: pd["quantity"],
      price_satoshis: pd["price_satoshis"],
      seller_address: pd["seller_address"],
      token_utxo: pd["token_utxo"],
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
