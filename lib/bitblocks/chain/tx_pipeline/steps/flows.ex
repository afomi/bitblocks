defmodule Bitblocks.Chain.TxPipeline.Steps.Flows do
  @moduledoc """
  Shared by the tally steps: a row's value flows (`Chain.RawTx.flows/1`),
  read from its raw hex. Exact satoshis, and no script parsing.
  """

  alias Bitblocks.Chain.RawTx

  @doc "`{:ok, flows}` for row attrs with a raw hex, else `:error`."
  def of(%{raw: raw}) when is_binary(raw) do
    case RawTx.flows(raw) do
      {:ok, flows} -> {:ok, flows}
      _ -> :error
    end
  end

  def of(_attrs), do: :error

  @doc "True for a coinbase: its one input spends no previous output."
  def coinbase?(%{inputs: [:coinbase]}), do: true
  def coinbase?(_flows), do: false

  @doc """
  True for a provably unspendable output: the script starts with OP_RETURN
  (0x6a) or OP_FALSE OP_RETURN (0x00 0x6a), so no unlocking script can
  satisfy it and its sats are gone for good.
  """
  def unspendable?(<<0x6A, _::binary>>), do: true
  def unspendable?(<<0x00, 0x6A, _::binary>>), do: true
  def unspendable?(_script), do: false
end
