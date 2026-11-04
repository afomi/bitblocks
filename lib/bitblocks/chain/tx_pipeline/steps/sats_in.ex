defmodule Bitblocks.Chain.TxPipeline.Steps.SatsIn do
  @moduledoc """
  `total_input_satoshis`: the sum of each input's previous output value.

  The sync loop fills blocks upward from genesis, so every previous tx is
  already stored when a tx comes in, and sats in costs no node call. A
  previous tx earlier in the same chunk isn't inserted yet; its outputs come
  from the chunk itself. The rest are one query per chunk (`lookup/1`) on
  the unique txid index, reading only the one output element each input
  needs.

  A coinbase spends nothing: 0. When any previous output isn't stored (an
  imported or WhatsOnChain-filled block can skip ahead), sats in is nil,
  meaning unknown; never guessed.
  """

  @behaviour Bitblocks.Chain.TxPipeline.Step

  alias Bitblocks.Chain.TxPipeline.Steps.Flows
  alias Bitblocks.Repo

  # Outpoints per lookup query; a chunk of 100 txs rarely needs more than one.
  @lookup_batch 5_000

  @impl true
  def name, do: "sats_in"

  @impl true
  def description,
    do: "Sums each input's previous output value from stored txs into total_input_satoshis."

  @impl true
  def stage, do: :chunk

  @impl true
  def run_chunk(attrs_list, _block) do
    flows = Enum.map(attrs_list, &Flows.of/1)

    local =
      for {attrs, {:ok, %{outputs: outputs}}} <- Enum.zip(attrs_list, flows),
          is_binary(attrs[:txid]),
          into: %{},
          do: {attrs.txid, Enum.map(outputs, &elem(&1, 0))}

    wanted =
      for {:ok, %{inputs: inputs}} <- flows,
          {txid, _vout} = outpoint <- inputs,
          not Map.has_key?(local, txid),
          uniq: true,
          do: outpoint

    stored = lookup(wanted)

    Enum.zip_with(attrs_list, flows, fn attrs, flow ->
      Map.put(attrs, :total_input_satoshis, sats_in(flow, local, stored))
    end)
  end

  defp sats_in(:error, _local, _stored), do: nil

  defp sats_in({:ok, %{inputs: inputs} = flows}, local, stored) do
    if Flows.coinbase?(flows) do
      0
    else
      Enum.reduce_while(inputs, 0, fn
        {txid, vout}, acc ->
          value =
            case local do
              %{^txid => values} -> Enum.at(values, vout)
              _ -> Map.get(stored, {txid, vout})
            end

          if is_integer(value), do: {:cont, acc + value}, else: {:halt, nil}

        :coinbase, _acc ->
          {:halt, nil}
      end)
    end
  end

  @doc """
  The stored value of each `{txid, vout}`, as `%{{txid, vout} => sats}`.
  Outpoints whose tx or output isn't stored are absent.

  One query per #{@lookup_batch} outpoints: `unnest` the pairs and join on
  the unique txid index, selecting only `outputs[vout + 1]`, so a tx with
  thousands of outputs sends back one element, not its whole array (Postgres
  still detoasts the array to take it; that read is most of the cost).
  """
  @spec lookup([{String.t(), non_neg_integer()}]) :: %{
          {String.t(), non_neg_integer()} => non_neg_integer()
        }
  def lookup([]), do: %{}

  def lookup(outpoints) do
    outpoints
    |> Enum.chunk_every(@lookup_batch)
    |> Enum.reduce(%{}, fn batch, acc ->
      {txids, vouts} = Enum.unzip(batch)

      %{rows: rows} =
        Repo.query!(
          """
          SELECT i.txid, i.vout, t.outputs[i.vout + 1]
          FROM unnest($1::varchar[], $2::int[]) AS i(txid, vout)
          JOIN transactions t ON t.txid = i.txid
          """,
          [txids, vouts]
        )

      Enum.reduce(rows, acc, fn [txid, vout, output], acc ->
        case output_value(output, vout) do
          nil -> acc
          sats -> Map.put(acc, {txid, vout}, sats)
        end
      end)
    end)
  end

  @doc """
  An output's value in satoshis from its stored JSON (`transactions.outputs`
  holds one getrawtransaction `vout` object per element). `valueSat` when
  present, else `value` in BSV: an exact integer below 2^53 once rounded.
  nil when the element is missing or names another index.
  """
  @spec output_value(String.t() | nil, non_neg_integer()) :: non_neg_integer() | nil
  def output_value(nil, _vout), do: nil

  def output_value(json, vout) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"n" => n}} when n != vout -> nil
      {:ok, %{"valueSat" => sats}} when is_integer(sats) and sats >= 0 -> sats
      {:ok, %{"value" => value}} when is_number(value) and value >= 0 -> round(value * 1.0e8)
      _ -> nil
    end
  end
end
