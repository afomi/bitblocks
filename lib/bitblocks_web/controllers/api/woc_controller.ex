defmodule BitblocksWeb.Api.WocController do
  @moduledoc """
  WhatsOnChain-compatible alias endpoints.

  These mirror the de-facto-standard WhatsOnChain response shapes so a client
  written against WoC can point at Bitblocks with minimal changes. Unlike the
  native `/api/v1` endpoints, responses here are **bare** (no `{data: ...}`
  envelope) and use WoC's field names (`tx_hash`, `tx_pos`, `value`, RPC-style
  block keys). The native enveloped API remains the primary, richer surface.

  Reads are served from local indexed data (`source` is implied local — only as
  current as sync). See docs/EXTERNAL_APIS.md for the mapping and rationale.

  Tier 1 (read): chain/info, tx hex, address unspent + balance.
  Tier 2 (broadcast + proof): POST tx/raw, TSC merkle proof.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Chain
  alias BitblocksWeb.Utils.BsvParams

  # --- Tier 1: chain info -----------------------------------------------------

  # GET /api/v1/woc/chain/info
  # Mirrors WoC /chain/info keys, mapped from our latest block + chain state.
  def chain_info(conn, _params) do
    case Chain.get_latest_block() do
      nil ->
        conn |> put_status(503) |> json(%{error: "No blocks synced"})

      block ->
        json(conn, %{
          chain: "main",
          blocks: block.height,
          headers: block.height,
          bestblockhash: block.hash,
          difficulty: block.difficulty,
          mediantime: block.mediantime,
          chainwork: block.chainwork
        })
    end
  end

  # --- Tier 1: raw tx hex -----------------------------------------------------

  # GET /api/v1/woc/tx/:txid/hex
  # Returns the raw transaction hex as a bare string, like WoC /tx/{txid}/hex.
  def tx_hex(conn, %{"txid" => txid}) do
    case Chain.get_transaction(txid) do
      %{raw: raw} when is_binary(raw) and raw != "" ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, raw)

      _ ->
        conn |> put_status(404) |> json(%{error: "Transaction not found"})
    end
  end

  # --- Tier 1: address UTXOs --------------------------------------------------

  # GET /api/v1/woc/address/:address/unspent
  # Bare array in WoC shape: [{height, tx_pos, tx_hash, value}].
  def address_unspent(conn, %{"address" => address}) do
    with {:ok, valid} <- BsvParams.address(address) do
      utxos =
        valid
        |> Chain.utxos_for_address()
        |> Enum.map(fn %{txid: txid, vout: vout, satoshis: sats, block_height: height} ->
          %{height: height, tx_pos: vout, tx_hash: txid, value: sats}
        end)

      json(conn, utxos)
    else
      {:error, :invalid_address} ->
        conn |> put_status(400) |> json(%{error: "Invalid address"})
    end
  end

  # --- Tier 1: address balance ------------------------------------------------

  # GET /api/v1/woc/address/:address/balance
  # WoC shape: {confirmed, unconfirmed}. We only index confirmed local data, so
  # unconfirmed is always 0 (documented limitation, not a silent omission).
  def address_balance(conn, %{"address" => address}) do
    with {:ok, valid} <- BsvParams.address(address) do
      json(conn, %{confirmed: Chain.balance_for_address(valid), unconfirmed: 0})
    else
      {:error, :invalid_address} ->
        conn |> put_status(400) |> json(%{error: "Invalid address"})
    end
  end

  # --- Tier 2: broadcast ------------------------------------------------------

  # POST /api/v1/woc/tx/raw   body: {"txhex": "..."}
  # Submits a raw tx to the node and returns the txid (WoC returns the txid
  # string on success). Errors surface the node's reason rather than a 200.
  def broadcast(conn, %{"txhex" => txhex}) when is_binary(txhex) and txhex != "" do
    case BitcoinsvCli.sendrawtransaction(txhex) do
      txid when is_binary(txid) ->
        json(conn, %{txid: txid})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: inspect(reason)})

      other ->
        conn |> put_status(400) |> json(%{error: inspect(other)})
    end
  end

  def broadcast(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Missing or empty txhex"})
  end

  # --- Tier 2: TSC merkle proof — DEFERRED ------------------------------------
  #
  # WoC exposes GET /tx/{txid}/proof/tsc returning a TSC-format merkle proof.
  # We only have the node's `gettxoutproof` today (a raw binary blob, served by
  # the native ProofController at /api/v1/txs/:txid/proof) — that is NOT TSC
  # format. Rather than mislabel a non-TSC blob as TSC, this alias is left
  # unimplemented until a real TSC encoder exists (build the merkle branch for
  # the txid and encode {index, txOrId, target, nodes}). See docs/EXTERNAL_APIS.md.
end
