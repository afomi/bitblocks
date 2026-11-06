defmodule Bitblocks.OrdinalCollections.Protocol do
  @moduledoc """
  How one kind of collection is minted and moves (#30). The engine
  (`Bitblocks.OrdinalCollections`) walks a mint chain from the collection's
  first link and traces items through spends; a protocol answers the
  protocol-specific questions from transaction bytes:

    * `mint/4`: does `tx`, which spends chain `link`, mint items? Which
      outputs hold them, and which outputs carry the chain on?
    * `landing/4`: an item spent as input `vin` of `tx` lands where? Or does
      its trail end there (`{:ended, reason}`, final and settled)?
    * `owner/1`: who holds an output (a P2PKH address, or nil for a contract)?

  Anything a protocol can't decide from the bytes is `:no` or `{:unknown,
  reason}`, never a guess. A lookup that failed (an input value we couldn't
  fetch) is `{:error, reason}`: the trace keeps what it knew and retries later.
  """

  @type item :: %{
          required(:vout) => non_neg_integer(),
          optional(:name) => String.t() | nil,
          optional(:content_type) => String.t() | nil,
          optional(:traits) => [map()],
          optional(:owner) => String.t() | nil
        }

  @typedoc "Value lookup for an outpoint, for protocols that need input values."
  @type value_of :: (BSV.OutPoint.t() -> {:ok, non_neg_integer()} | :error)

  @callback mint(tx :: BSV.Tx.t(), txid :: String.t(), link :: String.t(), config :: map()) ::
              {:ok, items :: [item()], next_links :: [String.t()]} | :no

  @callback landing(
              tx :: BSV.Tx.t(),
              txid :: String.t(),
              vin :: non_neg_integer(),
              value_of :: value_of()
            ) ::
              {:ok, String.t()}
              | {:ended, String.t()}
              | {:unknown, String.t()}
              | {:error, String.t()}

  @callback owner(BSV.TxOut.t()) :: String.t() | nil

  @doc """
  Whether a hop's tx mined on both sides of a reorg sends the item for a
  re-trace (#52, #53). When false, only a hop no block holds does.
  """
  @callback retrace_moved?() :: boolean()

  @doc "The membership rule, in words, for the explicit verification block."
  @callback rule() :: String.t()

  @doc "The input index of `tx` spending `outpoint` (\"txid_vout\"), or nil."
  def input_index(%BSV.Tx{inputs: inputs}, outpoint) do
    Enum.find_index(inputs, fn %BSV.TxIn{outpoint: op} ->
      "#{BSV.OutPoint.get_txid(op)}_#{op.vout}" == outpoint
    end)
  end
end
