defmodule BitblocksWeb.Api.ProofController do
  @moduledoc """
  `GET /api/v1/txs/:txid/proof`: a merkle inclusion proof a caller can check
  (#43). The JSON carries `index` and `siblings`, which climb from `txid` to
  `merkleroot`, and the block (`block_hash`, `block_height`, `confirmations`)
  whose proof-of-work-checked header commits to that root.

  Built and checked by `Bitblocks.Chain.MerkleProof`, which also says what
  "canonical" means here. Only a proof that climbed to the header's root is
  a 200:

    * 404: we don't store the tx;
    * 409: its block was orphaned or is no longer the one we hold at that height;
    * 500: the txid list or the node's tree doesn't rebuild the header's root,
      or the tx isn't in the block's list;
    * 503: the block's txid list isn't stored and the node gave no proof.

  Not a BEEF body (#17).
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Chain.MerkleProof

  @doc "GET /api/v1/txs/:txid/proof"
  def show(conn, %{"txid" => txid}) do
    case MerkleProof.build(txid) do
      {:ok, proof} ->
        json(conn, %{data: proof})

      {:error, :not_found} ->
        error(conn, 404, "Not found")

      {:error, :not_canonical} ->
        error(
          conn,
          409,
          "This transaction's block is not canonical in this index (orphaned by a reorg, or replaced at its height); no proof is given for its old root."
        )

      {:error, :merkleroot_mismatch} ->
        error(
          conn,
          500,
          "The block's transactions did not rebuild the merkle root in its header, so no proof is given."
        )

      {:error, :tx_not_in_block} ->
        error(
          conn,
          500,
          "The block's verified txid list does not contain this transaction, so no proof is given."
        )

      {:error, :proof_unavailable} ->
        error(
          conn,
          503,
          "This block's txid list is not stored and the node gave no proof; try again later."
        )
    end
  end

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
