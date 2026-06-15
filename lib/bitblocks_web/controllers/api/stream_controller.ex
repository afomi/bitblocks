defmodule BitblocksWeb.Api.StreamController do
  @moduledoc """
  Server-Sent Events stream for real-time blockchain events.

  GET /api/v1/stream/blocks     — new blocks as they sync
  GET /api/v1/stream/order-book — order book listing events
  """
  use BitblocksWeb, :controller

  alias BitblocksWeb.SseLimiter
  alias BitblocksWeb.Utils.BsvParams
  alias BitblocksWeb.Utils.IpHelper

  @pubsub Bitblocks.PubSub

  # Heartbeat cadence — also the granularity at which we check the lifetime cap.
  @heartbeat_ms 30_000

  # T2: hard ceiling on how long a single SSE connection may stay open. Without
  # this a client can hold a slot indefinitely; recycling forces reconnection so
  # slots churn and a stuck/abandoned connection can't camp a slot forever.
  # Clients should auto-reconnect (EventSource does by default).
  defp max_lifetime_ms do
    Application.get_env(:bitblocks, __MODULE__, [])
    |> Keyword.get(:max_lifetime_ms, 30 * 60_000)
  end

  @doc false
  def deadline, do: System.monotonic_time(:millisecond) + max_lifetime_ms()

  @doc false
  def expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  def blocks(conn, _params) do
    # T2: SSE handlers hold a process open indefinitely. Cap concurrent
    # connections (global + per-IP) so a client can't exhaust the server by
    # opening unbounded streams; release the slot when the loop exits.
    with_sse_slot(conn, fn conn ->
      Phoenix.PubSub.subscribe(@pubsub, "blockchain_events")
      Phoenix.PubSub.subscribe(@pubsub, "sync_pipeline")

      conn = start_event_stream(conn)
      stream_loop(conn, deadline())
    end)
  end

  def order_book(conn, params) do
    # T8: validate token_id before it becomes a PubSub topic so a crafted value
    # can't inject a `:` separator into the channel name. Reject up front,
    # outside the streaming path.
    case validate_token_id(params["token_id"]) do
      {:ok, token_id} ->
        with_sse_slot(conn, fn conn ->
          Phoenix.PubSub.subscribe(@pubsub, "order_book")

          if token_id do
            Phoenix.PubSub.subscribe(@pubsub, "order_book:token:#{token_id}")
          end

          conn = start_event_stream(conn)
          order_book_loop(conn, deadline())
        end)

      {:error, :invalid_token_id} ->
        conn |> put_status(400) |> json(%{error: "Invalid token_id"})
    end
  end

  # nil token_id means "all listings" — valid. A present one must pass validation.
  defp validate_token_id(nil), do: {:ok, nil}
  defp validate_token_id(token_id), do: BsvParams.token_id(token_id)

  # Reserve an SSE slot, run `fun` if one is available, and always release it.
  # Returns 503 when the global or per-IP concurrency cap is hit.
  defp with_sse_slot(conn, fun) do
    ip = IpHelper.get_ip_address(conn)

    case SseLimiter.acquire(ip) do
      :ok ->
        try do
          fun.(conn)
        after
          SseLimiter.release(ip)
        end

      {:error, :too_many_connections} ->
        conn
        |> put_resp_header("retry-after", "30")
        |> send_resp(503, "Too many concurrent stream connections. Retry later.")
    end
  end

  defp start_event_stream(conn) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # Send an initial heartbeat so the client knows the connection is live
    {:ok, conn} = chunk(conn, ": connected\n\n")
    conn
  end

  defp order_book_loop(conn, deadline) do
    receive do
      {:new_listing, listing} ->
        send_order_book_event(conn, "new_listing", listing, deadline)

      {:listing_cancelled, listing} ->
        send_order_book_event(conn, "listing_cancelled", listing, deadline)

      {:listing_filled, listing} ->
        send_order_book_event(conn, "listing_filled", listing, deadline)

      _ ->
        order_book_loop(conn, deadline)
    after
      @heartbeat_ms ->
        if expired?(deadline) do
          close_stream(conn)
        else
          case chunk(conn, ": heartbeat\n\n") do
            {:ok, conn} -> order_book_loop(conn, deadline)
            {:error, _} -> conn
          end
        end
    end
  end

  defp send_order_book_event(conn, event, listing, deadline) do
    payload = "event: #{event}\ndata: #{Jason.encode!(listing)}\n\n"

    case chunk(conn, payload) do
      {:ok, conn} -> order_book_loop(conn, deadline)
      {:error, _} -> conn
    end
  end

  defp stream_loop(conn, deadline) do
    receive do
      {:new_block, height, hash} ->
        send_event(conn, "new_block", %{height: height, hash: hash}, deadline)

      {:block_synced, block} ->
        send_event(conn, "block_synced", %{
          height: block.height,
          hash: block.hash,
          num_tx: block.num_tx,
          time: block.time
        }, deadline)

      {:new_blocks_detected, count} ->
        send_event(conn, "new_blocks_detected", %{count: count}, deadline)

      {:reorg_detected, old_tip, new_tip} ->
        send_event(conn, "reorg", %{old_tip: old_tip, new_tip: new_tip}, deadline)

      {:pipeline_progress, progress} ->
        send_event(conn, "sync_progress", progress, deadline)

      :pipeline_completed ->
        send_event(conn, "sync_completed", %{}, deadline)

      _ ->
        stream_loop(conn, deadline)
    after
      @heartbeat_ms ->
        if expired?(deadline) do
          close_stream(conn)
        else
          # Send heartbeat every 30s to keep the connection alive
          case chunk(conn, ": heartbeat\n\n") do
            {:ok, conn} -> stream_loop(conn, deadline)
            {:error, _} -> conn
          end
        end
    end
  end

  defp send_event(conn, event, data, deadline) do
    payload = "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"

    case chunk(conn, payload) do
      {:ok, conn} -> stream_loop(conn, deadline)
      {:error, _} -> conn
    end
  end

  # Lifetime cap reached — tell the client to reconnect, then end the response
  # so the slot is released (via the `after` block in with_sse_slot/2).
  defp close_stream(conn) do
    case chunk(conn, "event: reconnect\ndata: {\"reason\":\"max_lifetime\"}\n\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end
end
