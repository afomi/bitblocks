defmodule BitblocksWeb.Api.HodlockerController do
  @moduledoc """
  HodLocker over HTTP (#75, #76). Public chain data, read-only.

    * `GET /api/v1/hodlocker/posts/:txid` — what the locks we've indexed back
      a post with: sats locked, how many locks and txs, how many are likes,
      what is still locked at our tip, and the unlock heights' range. Read
      from the `timelocks` table (`Bitblocks.Timelocks.post_totals/2`), so a
      range not yet indexed is missing from it. `meta.indexed_through_height`
      says how far the index is known to reach (`Timelocks.indexed_through/1`;
      null until a backfill covers the chain from block 0).
  """
  use BitblocksWeb, :controller

  alias Bitblocks.{ChainTiles, SyncProgress, Timelocks}

  def post(conn, %{"txid" => txid}) do
    if txid =~ ~r/\A[0-9a-f]{64}\z/ do
      tip = ChainTiles.chain_tip()

      json(conn, %{
        data: Timelocks.post_totals(txid, tip),
        meta: %{
          tip_height: tip,
          indexed_through_height:
            Timelocks.indexed_through(SyncProgress.snapshot().overview.complete_through),
          source: "timelocks"
        }
      })
    else
      conn |> put_status(400) |> json(%{error: "A post is a txid: 64 lowercase hex characters."})
    end
  end
end
