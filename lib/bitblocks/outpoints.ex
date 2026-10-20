defmodule Bitblocks.Outpoints do
  @moduledoc """
  Answers "is this outpoint an ordinal or token?" for wallets that fail closed.

  qart's UTXO spending policy spends only outputs it is sure are cash, so the
  answer is three-valued and `:unknown` is the default:

    * `:yes` — the output carries an inscription envelope (`OP_FALSE OP_IF "ord"`),
      or a protocol instance (BSV-20/21 token, order-book listing) is indexed at
      this outpoint.
    * `:no` — the transaction is indexed, the output has no envelope and no
      protocol instance, and it holds more than 1 satoshi. 1Sat Ordinals only
      track sats in 1-sat outputs, so such an output is plain cash.
    * `:unknown` — the transaction isn't indexed (or its raw bytes aren't
      stored), or the output is a bare 1-sat output: an inscribed sat can be
      moved into a plain 1-sat P2PKH with no envelope, and we don't trace sat
      lineage, so we can't say it's cash.
  """

  alias Bitblocks.Bsv20Parser
  alias Bitblocks.Chain
  alias Bitblocks.Chain.SafeTx
  alias Bitblocks.ProtocolRegistry
  alias Bitblocks.Repo

  @type answer ::
          {:yes, kind :: String.t(), reason :: String.t()}
          | {:no, reason :: String.t()}
          | {:unknown, reason :: String.t()}

  @doc """
  Classifies the outpoint `txid:vout`.

  Returns an `t:answer/0`, or `{:error, :vout_out_of_range}` when the
  transaction is indexed but has no output at `vout`.
  """
  @spec classify(String.t(), non_neg_integer()) :: answer() | {:error, :vout_out_of_range}
  def classify(txid, vout) when is_binary(txid) and is_integer(vout) and vout >= 0 do
    with {:ok, tx} <- indexed_tx(txid),
         {:ok, output} <- output_at(tx, vout) do
      classify_output(txid, vout, output)
    end
  end

  defp indexed_tx(txid) do
    case Chain.get_transaction(txid) do
      nil ->
        {:unknown, "transaction not indexed"}

      %{raw: raw} when raw in [nil, ""] ->
        {:unknown, "transaction indexed without raw bytes"}

      %{raw: raw} ->
        case SafeTx.from_hex(raw) do
          {:ok, tx} -> {:ok, tx}
          {:error, _} -> {:unknown, "stored transaction could not be decoded"}
        end
    end
  end

  defp output_at(%BSV.Tx{outputs: outputs}, vout) do
    case Enum.at(outputs, vout) do
      nil -> {:error, :vout_out_of_range}
      output -> {:ok, output}
    end
  end

  defp classify_output(txid, vout, %BSV.TxOut{satoshis: satoshis, script: script}) do
    cond do
      instance = ProtocolRegistry.get_instance(txid, vout) ->
        {:yes, instance_kind(instance), "protocol instance indexed at this outpoint"}

      inscription?(script.chunks) ->
        {:yes, inscription_kind(script), "output script carries an inscription envelope"}

      satoshis == 1 ->
        {:unknown, "1-sat output without an envelope; sat lineage is not traced"}

      true ->
        {:no, "indexed output with no inscription or token"}
    end
  end

  defp inscription?([marker, :OP_IF, "ord" | _]) when marker in [:OP_FALSE, :OP_0], do: true
  defp inscription?([_ | rest]), do: inscription?(rest)
  defp inscription?([]), do: false

  defp inscription_kind(script) do
    case Bsv20Parser.parse(script) do
      {:ok, %{standard: standard}} -> standard
      _ -> "ordinal"
    end
  end

  defp instance_kind(instance) do
    case instance.parsed_data do
      %{"standard" => standard} when is_binary(standard) ->
        standard

      _ ->
        instance
        |> Repo.preload(:protocol)
        |> Map.get(:protocol)
        |> case do
          %{name: name} -> name
          nil -> "protocol"
        end
    end
  end
end
