defmodule BitblocksWeb.Api.TokenController do
  @moduledoc """
  Read API for indexed BSV-20 / BSV-21 tokens.

  Serves token genesis records (deploy+mint), holder balances, and transfer
  history from local index data — the read side of the DEX. Composing and
  broadcasting mints is the wallet layer's job (qart); there is no write endpoint
  here.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Tokens
  alias BitblocksWeb.Utils.BsvParams

  action_fallback BitblocksWeb.FallbackController

  @doc """
  List indexed tokens.

  GET /api/v1/tokens
  Query params: standard ("bsv-21" | "bsv-20"), sym, cursor, per_page
  """
  def index(conn, params) do
    opts =
      []
      |> maybe_put(:standard, params["standard"])
      |> maybe_put(:sym, params["sym"])
      |> maybe_put(:cursor, params["cursor"])
      |> maybe_put(:limit, parse_int(params["per_page"]) || 50)

    tokens = Tokens.list_tokens(opts)

    json(conn, %{data: Enum.map(tokens, &token_to_json/1), count: length(tokens)})
  end

  @doc """
  Get a single token by its token_id (`<txid>_<vout>`) or ticker.

  GET /api/v1/tokens/:id
  """
  def show(conn, %{"id" => id}) do
    case BsvParams.token_ref(id) do
      {:ok, id} ->
        case Tokens.get_token(id) do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Token not found", id: id})

          token ->
            json(conn, %{data: token_to_json(token)})
        end

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "Invalid token id"})
    end
  end

  @doc """
  Holder balances for a token (summed transfer credits, most-held first).

  GET /api/v1/tokens/:id/holders
  """
  def holders(conn, %{"id" => id}) do
    case BsvParams.token_ref(id) do
      {:ok, id} ->
        holders = Tokens.token_holders(id)
        json(conn, %{token_id: id, count: length(holders), data: holders})

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "Invalid token id"})
    end
  end

  @doc """
  Recent transfers for a token, most recent first.

  GET /api/v1/tokens/:id/transfers
  Query params: per_page
  """
  def transfers(conn, %{"id" => id} = params) do
    case BsvParams.token_ref(id) do
      {:ok, id} ->
        opts = maybe_put([], :limit, parse_int(params["per_page"]) || 50)
        transfers = Tokens.token_transfers(id, opts)

        json(conn, %{
          token_id: id,
          count: length(transfers),
          data: Enum.map(transfers, &token_to_json/1)
        })

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "Invalid token id"})
    end
  end

  @doc """
  Aggregate token statistics.

  GET /api/v1/tokens/stats
  """
  def stats(conn, _params) do
    json(conn, %{data: Tokens.token_stats()})
  end

  # -- Private ----------------------------------------------------------------

  defp token_to_json(token) do
    %{
      standard: token.standard,
      op: token.op,
      txid: token.txid,
      vout: token.vout,
      block_height: token.block_height,
      token_id: token.token_id,
      tick: token.tick,
      sym: token.sym,
      amt: token.amt,
      max: token.max,
      lim: token.lim,
      dec: token.dec,
      icon: token.icon,
      recipient: token.recipient,
      supply: token.supply,
      minted: token.minted,
      holders: token.holders,
      inserted_at: token.inserted_at
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val
end
