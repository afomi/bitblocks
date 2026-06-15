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
    # T11: nonce/timestamp are untrusted. Both are 32-bit header fields, packed
    # as `::little-32` downstream — a non-numeric value crashed `String.to_integer`
    # and an out-of-range value crashed the binary construction. Parse totally and
    # bound to an unsigned 32-bit int, returning 400 instead of raising.
    with {:ok, nonce} <- parse_u32(nonce),
         {:ok, timestamp} <- parse_u32(timestamp) do
      submit_solution(conn, work_id, nonce, timestamp)
    else
      {:error, :invalid_u32} ->
        conn
        |> put_status(400)
        |> json(%{error: "nonce and timestamp must be unsigned 32-bit integers"})
    end
  end

  def submit(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Missing required fields: work_id, nonce, timestamp"})
  end

  defp submit_solution(conn, work_id, nonce, timestamp) do
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

  # Total parse to an unsigned 32-bit integer (0..2^32-1). Accepts an integer or
  # a decimal string; rejects everything else (no raise on bad input).
  @u32_max 0xFFFFFFFF

  defp parse_u32(n) when is_integer(n) and n >= 0 and n <= @u32_max, do: {:ok, n}

  defp parse_u32(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 and n <= @u32_max -> {:ok, n}
      _ -> {:error, :invalid_u32}
    end
  end

  defp parse_u32(_), do: {:error, :invalid_u32}

  @doc """
  Mining proxy status.

  GET /api/v1/mining/status
  """
  def status(conn, _params) do
    json(conn, %{data: MiningProxy.status()})
  end
end
