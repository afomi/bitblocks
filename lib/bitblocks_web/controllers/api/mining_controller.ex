defmodule BitblocksWeb.Api.MiningController do
  @moduledoc """
  Mining endpoints — serve block templates and accept solutions.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.MiningProxy

  action_fallback BitblocksWeb.FallbackController

  @doc """
  Get the current work unit.

  GET /api/v1/mining/work
  GET /api/v1/mining/work?address=1ABC...&message=my+miner

  When `address` is provided, the coinbase tx splits the reward:
  the configured platform share goes to bitblocks, the rest to the hasher.
  The `message` (optional) is appended to the coinbase scriptSig.
  """
  def work(conn, params) do
    opts = %{
      hasher_address: params["address"],
      hasher_message: params["message"]
    }

    case MiningProxy.get_work(opts) do
      nil ->
        conn |> put_status(503) |> json(%{error: "No work available. Mining proxy may be disabled or node unreachable."})

      work ->
        json(conn, %{
          data: %{
            work_id: work.work_id,
            header: %{
              version: work.version,
              prev_hash: work.prev_hash,
              merkle_root: work.merkle_root,
              timestamp: work.timestamp,
              bits: work.bits
            },
            target: work.target,
            height: work.height,
            created_at: work.created_at
          }
        })
    end
  end

  @doc """
  Submit a solution.

  POST /api/v1/mining/submit
  """
  def submit(conn, %{"work_id" => work_id, "nonce" => nonce, "timestamp" => timestamp}) do
    nonce = if is_binary(nonce), do: String.to_integer(nonce), else: nonce
    timestamp = if is_binary(timestamp), do: String.to_integer(timestamp), else: timestamp

    case MiningProxy.submit(work_id, nonce, timestamp) do
      {:ok, block_hash} ->
        json(conn, %{status: "accepted", block_hash: block_hash})

      {:error, :stale_work} ->
        conn |> put_status(409) |> json(%{status: "rejected", reason: "stale work — template has changed"})

      {:error, :no_work} ->
        conn |> put_status(503) |> json(%{status: "rejected", reason: "no work available"})

      {:error, :hash_above_target} ->
        conn |> put_status(422) |> json(%{status: "rejected", reason: "hash does not meet target"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{status: "rejected", reason: inspect(reason)})
    end
  end

  def submit(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Missing required fields: work_id, nonce, timestamp"})
  end

  @doc """
  Mining proxy status.

  GET /api/v1/mining/status
  """
  def status(conn, _params) do
    json(conn, %{data: MiningProxy.status()})
  end
end
