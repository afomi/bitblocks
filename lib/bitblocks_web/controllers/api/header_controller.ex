defmodule BitblocksWeb.Api.HeaderController do
  @moduledoc """
  Block headers for a caller checking merkle roots on its own: the 80-byte
  header as hex, with its hash, height, merkle root and `verified` and
  `canonical` flags (`Bitblocks.Chain.Headers` says what those mean). Rely on a
  header only when both are true.

    * `GET /api/v1/headers/:height`: 404 when we hold no header there.
    * `GET /api/v1/headers?from=<height>&limit=<n>`: up to 2,000 headers in
      height order, by the height index. `meta.missing` names heights in the
      range we don't hold, and `meta.next_from` is where to carry on.

  These cover the headers this index holds, up to `meta.tip_height`. They are
  our own view of the chain from one node.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Chain.Headers
  alias Bitblocks.Sync

  @default_limit 100
  @max_limit 2_000

  @covers "The headers this index holds, from one node, up to tip_height. " <>
            "Rely on a header only when verified and canonical are both true."

  @doc "GET /api/v1/headers/:height"
  def show(conn, %{"height" => height}) do
    case parse_height(height) do
      {:ok, height} ->
        case Headers.at(height) do
          nil -> error(conn, 404, "We hold no header at this height")
          header -> json(conn, %{data: header, meta: %{tip_height: Sync.tip(), covers: @covers}})
        end

      :error ->
        error(conn, 400, "Expected a block height")
    end
  end

  @doc "GET /api/v1/headers?from=&limit="
  def index(conn, %{"from" => from} = params) do
    with {:ok, from} <- parse_height(from),
         {:ok, limit} <- parse_limit(Map.get(params, "limit")) do
      headers = Headers.range(from, limit)
      tip = Sync.tip()
      json(conn, %{data: headers, meta: meta(headers, from, limit, tip)})
    else
      :error -> error(conn, 400, "Expected from=<height> and limit=<1..#{@max_limit}>")
    end
  end

  def index(conn, _params), do: error(conn, 400, "Expected from=<height>")

  defp meta(headers, from, limit, tip) do
    last = last_height(from, limit, tip)
    held = MapSet.new(headers, & &1.height)

    %{
      from: from,
      limit: limit,
      max_limit: @max_limit,
      count: length(headers),
      tip_height: tip,
      missing: for(h <- from..last//1, not MapSet.member?(held, h), do: h),
      next_from: if(tip && from + limit <= tip, do: from + limit),
      covers: @covers
    }
  end

  # The range's end, stopping at the tip: heights above it aren't missing, they
  # haven't happened or haven't reached us.
  defp last_height(_from, _limit, nil), do: -1
  defp last_height(from, limit, tip), do: min(from + limit - 1, tip)

  defp parse_height(value) when is_binary(value) do
    # Past the 32-bit column no block is held: too long to mean a height.
    if value =~ ~r/\A\d{1,10}\z/ do
      height = String.to_integer(value)
      if height <= Headers.max_height(), do: {:ok, height}, else: :error
    else
      :error
    end
  end

  defp parse_height(_value), do: :error

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..@max_limit -> {:ok, limit}
      _ -> :error
    end
  end

  defp parse_limit(_value), do: :error

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
