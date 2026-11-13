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

  `GET /api/v1/txs/:txid/beef` wraps the same proofs as BEEF (#17,
  `Bitblocks.Chain.Beef`), with the same errors.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Chain.{Beef, MerkleProof}

  @doc "GET /api/v1/txs/:txid/proof"
  def show(conn, %{"txid" => txid}) do
    case MerkleProof.build(String.downcase(txid)) do
      {:ok, proof} -> json(conn, %{data: proof})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @doc """
  GET /api/v1/txs/:txid/beef: `data.beef` is BRC-62 BEEF as hex, the tx last
  and carrying its own BUMP, its parents ahead of it. `parents_missing` names
  the parents left out, and `complete` is false when there are any; the BEEF
  is valid either way. `?format=atomic` gives Atomic BEEF (BRC-95): the tx and
  its BUMP alone, since its ancestry stops at its own proof. `format` in the
  answer says which it is.
  """
  def beef(conn, %{"txid" => txid} = params) do
    case beef_format(params) do
      {:ok, format} ->
        case Beef.build(String.downcase(txid), format: format) do
          {:ok, beef} -> json(conn, %{data: beef})
          {:error, reason} -> refuse(conn, reason)
        end

      :error ->
        error(conn, 400, "format can be beef or atomic")
    end
  end

  defp beef_format(%{"format" => "atomic"}), do: {:ok, :atomic}
  defp beef_format(%{"format" => "beef"}), do: {:ok, :beef}
  defp beef_format(%{"format" => _other}), do: :error
  defp beef_format(_params), do: {:ok, :beef}

  defp refuse(conn, reason) do
    case reason do
      :not_found ->
        error(conn, 404, "Not found")

      :not_canonical ->
        error(
          conn,
          409,
          "This transaction's block is not canonical in this index (orphaned by a reorg, or replaced at its height); no proof is given for its old root."
        )

      :merkleroot_mismatch ->
        error(
          conn,
          500,
          "The block's transactions did not rebuild the merkle root in its header, so no proof is given."
        )

      :tx_not_in_block ->
        error(
          conn,
          500,
          "The block's verified txid list does not contain this transaction, so no proof is given."
        )

      :proof_unavailable ->
        error(
          conn,
          503,
          "This block's txid list is not stored and the node gave no proof; try again later."
        )

      :raw_unavailable ->
        error(conn, 503, "This transaction's bytes could not be read; try again later.")

      :too_large ->
        conn
        |> put_status(413)
        |> json(%{
          error:
            "This BEEF would be over #{Beef.max_bytes()} bytes, the most we accept or serve. " <>
              "The transaction's bytes and its merkle proof carry the same evidence.",
          reason: :too_large,
          max_bytes: Beef.max_bytes(),
          raw_url: "/api/v1/txs/#{String.downcase(conn.path_params["txid"])}/raw",
          proof_url: "/api/v1/txs/#{String.downcase(conn.path_params["txid"])}/proof"
        })
    end
  end

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
