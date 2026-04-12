defmodule BitblocksWeb.Api.BlockController do
  use BitblocksWeb, :controller

  alias Bitblocks.Chain

  action_fallback BitblocksWeb.FallbackController

  @doc """
  List blocks, most recent first.

  GET /api/v1/blocks?page=1&per_page=50
  """
  def index(conn, params) do
    page = parse_int(params["page"], 1)
    per_page = parse_int(params["per_page"], 50) |> min(100)

    blocks = Chain.list_blocks(page: page, per_page: per_page)
    total = Chain.count_blocks()

    json(conn, %{
      data: Enum.map(blocks, &block_to_json/1),
      meta: %{
        total: total,
        page: page,
        per_page: per_page
      }
    })
  end

  @doc """
  Get a single block by height or hash.

  GET /api/v1/blocks/:id
  """
  def show(conn, %{"id" => id}) do
    case Chain.get_block(id) do
      nil -> {:error, :not_found}
      block -> json(conn, %{data: block_to_json(block)})
    end
  end

  @doc """
  Get the latest block.

  GET /api/v1/blocks/latest
  """
  def latest(conn, _params) do
    case Chain.get_latest_block() do
      nil -> {:error, :not_found}
      block -> json(conn, %{data: block_to_json(block)})
    end
  end

  @doc """
  Translate between UTC time and block height.

  GET /api/v1/blocks/at_time?t=2024-01-01T00:00:00Z
  GET /api/v1/blocks/at_height?h=823000
  """
  def at_time(conn, %{"t" => time_str}) do
    case DateTime.from_iso8601(time_str) do
      {:ok, datetime, _offset} ->
        case Chain.height_at_time(datetime) do
          {:ok, height} -> json(conn, %{data: %{height: height, time: time_str}})
          {:error, :not_found} -> {:error, :not_found}
        end

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "Invalid ISO8601 datetime"})
    end
  end

  def at_height(conn, %{"h" => height_str}) do
    case Integer.parse(height_str) do
      {height, ""} ->
        case Chain.time_at_height(height) do
          {:ok, datetime} ->
            json(conn, %{data: %{height: height, time: DateTime.to_iso8601(datetime)}})

          {:error, :not_found} ->
            {:error, :not_found}
        end

      _ ->
        conn |> put_status(400) |> json(%{error: "Invalid height"})
    end
  end

  @doc """
  Get sampled height↔time pairs for building scrubber UIs.

  GET /api/v1/blocks/time_map?from=0&to=900000&step=10000
  """
  def time_map(conn, params) do
    from = parse_int(params["from"], 0)
    to = parse_int(params["to"], 900_000)
    step = parse_int(params["step"], 10_000) |> max(100)

    samples = Chain.height_time_samples(from, to, step)

    json(conn, %{
      data:
        Enum.map(samples, fn {height, datetime} ->
          %{height: height, time: DateTime.to_iso8601(datetime)}
        end),
      meta: %{from: from, to: to, step: step, count: length(samples)}
    })
  end

  defp block_to_json(block) do
    %{
      hash: block.hash,
      height: block.height,
      version: block.version,
      merkleroot: block.merkleroot,
      time: block.time,
      mediantime: block.mediantime,
      nonce: block.nonce,
      bits: block.bits,
      difficulty: block.difficulty,
      chainwork: block.chainwork,
      num_tx: block.num_tx,
      size: block.size,
      prevblockhash: block.prevblockhash,
      nextblockhash: block.nextblockhash,
      sync_state: block.sync_state
    }
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> max(n, 1)
      _ -> default
    end
  end
  defp parse_int(val, _default) when is_integer(val), do: val
end
