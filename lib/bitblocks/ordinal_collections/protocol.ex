defmodule Bitblocks.OrdinalCollections.Protocol do
  @moduledoc """
  How one kind of collection is minted and moves (#30). The engine
  (`Bitblocks.OrdinalCollections`) walks a mint chain from the collection's
  first link and traces items through spends; a protocol answers the
  protocol-specific questions from transaction bytes:

    * `mint/4`: does `tx`, which spends chain `link`, mint items? Which
      outputs hold them, and which outputs carry the chain on?
    * `landing/4`: an item spent as input `vin` of `tx` lands where?
    * `owner/1`: who holds an output (a P2PKH address, or nil for a contract)?

  Anything a protocol can't decide from the bytes is `:no` or `{:unknown,
  reason}`, never a guess.
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
            ) :: {:ok, String.t()} | {:unknown, String.t()}

  @callback owner(BSV.TxOut.t()) :: String.t() | nil

  @doc "The input index of `tx` spending `outpoint` (\"txid_vout\"), or nil."
  def input_index(%BSV.Tx{inputs: inputs}, outpoint) do
    Enum.find_index(inputs, fn %BSV.TxIn{outpoint: op} ->
      "#{BSV.OutPoint.get_txid(op)}_#{op.vout}" == outpoint
    end)
  end
end
