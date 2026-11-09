defmodule BitblocksWeb.Api.AddressController do
  @moduledoc """
  Address endpoints, served from local data (`spend_index` and the raw txs
  tagged with the address in `output_addresses`).

  `/utxos` and `/balance` are exact or say they are not, by the rule in
  `Bitblocks.Chain.Utxos`: an output is unspent only when no stored tx
  spends it and every block through our tip is synced. Each answer has a
  `status` (`exact`, `partial` or `unknown`), `indexed_through_height` and
  `tip_height`, and `source: "local"`.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{AddressHistory, Utxos}
  alias BitblocksWeb.Utils.BsvParams

  action_fallback BitblocksWeb.FallbackController

  @doc """
  Unspent outputs for an address.

  GET /api/v1/addresses/:address/utxos

  `data` lists only outputs known to be unspent, so it is empty unless the
  index reaches the tip. `unknown` lists outputs with no recorded spend
  whose spent-ness isn't settled yet; don't spend those on our word.
  """
  def utxos(conn, %{"address" => address}) do
    with {:ok, valid} <- BsvParams.address(address) do
      set = Utxos.for_address(valid)
      unspent = Utxos.with_status(set, :unspent)

      json(conn, %{
        data: unspent,
        unknown: Utxos.with_status(set, :unknown),
        meta: %{
          address: valid,
          count: length(unspent),
          status: set.status,
          indexed_through_height: set.indexed_through_height,
          tip_height: set.tip_height,
          source: "local"
        }
      })
    else
      {:error, :invalid_address} ->
        conn |> put_status(400) |> json(%{error: "Invalid address"})
    end
  end

  @doc """
  Balance for an address.

  GET /api/v1/addresses/:address/balance

  `data` has `status`, `indexed_through_height` and `tip_height`. When
  `status` is `exact` it has `confirmed` (satoshis); otherwise it has
  `unknown` (satoshis in outputs with no recorded spend that may be spent
  in blocks not synced yet) and no `confirmed` key.
  """
  def balance(conn, %{"address" => address}) do
    with {:ok, valid} <- BsvParams.address(address) do
      json(conn, %{
        data: Utxos.balance(valid),
        meta: %{address: valid, source: "local"}
      })
    else
      {:error, :invalid_address} ->
        conn |> put_status(400) |> json(%{error: "Invalid address"})
    end
  end

  @doc """
  Every confirmed tx that touched an address, newest first (#80).

  GET /api/v1/addresses/:address/history?limit=&cursor=

  Each row has `txid`, `height`, `net_sats` (nil with `net_sats_reason`
  when an input's value isn't known) and `source` (`local` or
  `whatsonchain`). `meta` has `status` (`exact`, `partial` or `unknown`),
  `indexed_through_height`, `tip_height`, `next_cursor` and `sources`.
  Our index answers through `indexed_through_height`, WhatsOnChain above
  it (`Bitblocks.Chain.AddressHistory`). `limit` is 50 by default, at
  most 200; `cursor` is the previous page's `meta.next_cursor`.
  """
  def history(conn, %{"address" => address} = params) do
    with {:ok, valid} <- BsvParams.address(address),
         {:ok, cursor} <- Chain.decode_tx_cursor(params["cursor"]),
         {:ok, limit} <- limit_param(params["limit"]) do
      page = AddressHistory.page(valid, cursor: cursor, limit: limit)

      json(conn, %{
        data: page.rows,
        meta:
          page
          |> Map.take([:status, :indexed_through_height, :tip_height, :next_cursor, :sources])
          |> Map.merge(%{address: valid, count: length(page.rows), limit: limit})
      })
    else
      {:error, :invalid_address} ->
        conn |> put_status(400) |> json(%{error: "Invalid address"})

      {:error, :invalid_limit} ->
        conn
        |> put_status(400)
        |> json(%{
          error: "Invalid limit: a whole number from 1 to #{AddressHistory.max_limit()}."
        })

      :error ->
        conn
        |> put_status(400)
        |> json(%{error: "Invalid cursor: use meta.next_cursor from the previous page."})
    end
  end

  defp limit_param(nil), do: {:ok, AddressHistory.default_limit()}
  defp limit_param(""), do: {:ok, AddressHistory.default_limit()}

  defp limit_param(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 1 -> {:ok, min(n, AddressHistory.max_limit())}
      _ -> {:error, :invalid_limit}
    end
  end

  @doc """
  Unspent BSV-20/21 token outputs held by an address — the wallet-basket view
  (BRC-163 basket `bsv21`).

  GET /api/v1/addresses/:address/tokens?standard=bsv-21&token_id=<txid>_<vout>
  """
  def tokens(conn, %{"address" => address} = params) do
    with {:ok, valid} <- BsvParams.address(address),
         {:ok, standard} <- standard_param(params["standard"]),
         {:ok, token_id} <- token_id_param(params["token_id"]) do
      outputs = Bitblocks.Tokens.unspent_outputs(valid, standard: standard, token_id: token_id)

      json(conn, %{
        data: outputs,
        meta: %{address: valid, count: length(outputs), source: "local"}
      })
    else
      {:error, :invalid_address} -> conn |> put_status(400) |> json(%{error: "Invalid address"})
      {:error, :invalid_standard} -> conn |> put_status(400) |> json(%{error: "Invalid standard"})
      {:error, :invalid_token_id} -> conn |> put_status(400) |> json(%{error: "Invalid token_id"})
    end
  end

  defp standard_param(nil), do: {:ok, nil}
  defp standard_param(standard) when standard in ["bsv-20", "bsv-21"], do: {:ok, standard}
  defp standard_param(_), do: {:error, :invalid_standard}

  defp token_id_param(nil), do: {:ok, nil}
  defp token_id_param(token_id), do: BsvParams.token_id(token_id)
end
