defmodule BitblocksWeb.Api.ProofController do
  @moduledoc """
  Merkle proof endpoint — returns a proof that a transaction
  is included in a block, anchored to the block header.

  The consumer can verify locally without trusting bitblocks.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Chain

  action_fallback BitblocksWeb.FallbackController

  @doc """
  Get a merkle proof for a transaction.

  GET /api/v1/txs/:txid/proof
  """
  def show(conn, %{"txid" => txid}) do
    with tx when not is_nil(tx) <- Chain.get_transaction_by_txid(txid),
         block when not is_nil(block) <- Chain.get_block(tx.block_hash),
         {:ok, proof_hex} <- fetch_proof(txid, tx.block_hash) do
      json(conn, %{
        data: %{
          txid: txid,
          block_hash: block.hash,
          block_height: block.height,
          merkleroot: block.merkleroot,
          proof: proof_hex
        }
      })
    else
      nil -> {:error, :not_found}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp fetch_proof(txid, block_hash) do
    case BitcoinsvCli.gettxoutproof([txid], block_hash) do
      hex when is_binary(hex) -> {:ok, hex}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :proof_unavailable}
    end
  end
end
