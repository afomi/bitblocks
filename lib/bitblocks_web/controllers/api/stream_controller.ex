defmodule BitblocksWeb.Api.StreamController do
  @moduledoc """
  Server-Sent Events stream for real-time blockchain events.

  GET /api/v1/stream/blocks     — new blocks as they sync
  GET /api/v1/stream/order-book — order book listing events
  """
  use BitblocksWeb, :controller

  @pubsub Bitblocks.PubSub

  def blocks(conn, _params) do
    Phoenix.PubSub.subscribe(@pubsub, "blockchain_events")
    Phoenix.PubSub.subscribe(@pubsub, "sync_pipeline")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # Send an initial heartbeat so the client knows the connection is live
    {:ok, conn} = chunk(conn, ": connected\n\n")

    stream_loop(conn)
  end

  def order_book(conn, params) do
    Phoenix.PubSub.subscribe(@pubsub, "order_book")

    if token_id = params["token_id"] do
      Phoenix.PubSub.subscribe(@pubsub, "order_book:token:#{token_id}")
    end

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, ": connected\n\n")

    order_book_loop(conn)
  end

  defp order_book_loop(conn) do
    receive do
      {:new_listing, listing} ->
        send_order_book_event(conn, "new_listing", listing)

      {:listing_cancelled, listing} ->
        send_order_book_event(conn, "listing_cancelled", listing)

      {:listing_filled, listing} ->
        send_order_book_event(conn, "listing_filled", listing)

      _ ->
        order_book_loop(conn)
    after
      30_000 ->
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> order_book_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  defp send_order_book_event(conn, event, listing) do
    payload = "event: #{event}\ndata: #{Jason.encode!(listing)}\n\n"

    case chunk(conn, payload) do
      {:ok, conn} -> order_book_loop(conn)
      {:error, _} -> conn
    end
  end

  defp stream_loop(conn) do
    receive do
      {:new_block, height, hash} ->
        send_event(conn, "new_block", %{height: height, hash: hash})

      {:block_synced, block} ->
        send_event(conn, "block_synced", %{
          height: block.height,
          hash: block.hash,
          num_tx: block.num_tx,
          time: block.time
        })

      {:new_blocks_detected, count} ->
        send_event(conn, "new_blocks_detected", %{count: count})

      {:reorg_detected, old_tip, new_tip} ->
        send_event(conn, "reorg", %{old_tip: old_tip, new_tip: new_tip})

      {:pipeline_progress, progress} ->
        send_event(conn, "sync_progress", progress)

      :pipeline_completed ->
        send_event(conn, "sync_completed", %{})

      _ ->
        stream_loop(conn)
    after
      30_000 ->
        # Send heartbeat every 30s to keep the connection alive
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  defp send_event(conn, event, data) do
    payload = "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"

    case chunk(conn, payload) do
      {:ok, conn} -> stream_loop(conn)
      {:error, _} -> conn
    end
  end
end
