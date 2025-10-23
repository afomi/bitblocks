defmodule Bitblocks.Analytics.AddressConcentration do
  @moduledoc """
  Computes and caches address concentration snapshots directly from the local chain data.

  The aggregator walks transactions up to a target height, maintaining a lightweight
  UTXO map to reconstruct balances without relying on external APIs such as WOC.
  Snapshots are cached to disk (`priv/cache/address_concentration`) so we can refresh
  them on a schedule (e.g., daily) without recomputing during every request.
  """

  import Ecto.Query, warn: false

  alias Bitblocks.Analytics.RewardInsights
  alias Bitblocks.Chain.Transaction
  alias Bitblocks.Repo

  require Logger

  @phase_defaults RewardInsights.phases()
  @snapshot_dir Path.join(:code.priv_dir(:bitblocks), "cache/address_concentration")
  @cache_ttl :timer.hours(24)
  @top_limit 200

  def snapshot(phase) when is_binary(phase) do
    {start_height, requested_end} =
      Map.get(@phase_defaults, phase, Map.get(@phase_defaults, "200k"))

    latest_height = current_chain_height()

    end_height =
      case requested_end do
        :latest when latest_height > 0 -> latest_height
        :latest -> latest_height
        value -> min(value, latest_height)
      end

    cond do
      latest_height == 0 ->
        {:error, :no_blocks}

      end_height <= 0 ->
        {:error, :invalid_range}

      true ->
        load_or_compute_snapshot(phase, start_height, end_height)
    end
  end

  def snapshot(_), do: {:error, :unknown_phase}

  defp load_or_compute_snapshot(phase, start_height, end_height) do
    File.mkdir_p!(@snapshot_dir)
    cache_file = Path.join(@snapshot_dir, "#{phase}.json")

    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(cache_file),
         true <- fresh?(mtime),
         {:ok, json} <- File.read(cache_file),
         {:ok, payload} <- Jason.decode(json) do
      {:ok, Map.put(payload, "source", "cache")}
    else
      {:error, :enoent} ->
        compute_and_cache(phase, start_height, end_height, cache_file)

      false ->
        compute_and_cache(phase, start_height, end_height, cache_file)

      {:error, _reason} ->
        compute_and_cache(phase, start_height, end_height, cache_file)
    end
  end

  defp fresh?(mtime) do
    now = DateTime.utc_now()

    diff =
      now
      |> DateTime.to_unix()
      |> Kernel.-(DateTime.to_unix(DateTime.from_unix!(mtime)))

    diff < div(@cache_ttl, 1000)
  rescue
    _ -> false
  end

  defp compute_and_cache(phase, start_height, end_height, cache_file) do
    Logger.info(
      "Computing address concentration snapshot for phase=#{phase} (#{start_height}-#{end_height})"
    )

    case compute_snapshot(start_height, end_height) do
      {:ok, result} ->
        payload =
          result
          |> Map.put(:source, "computed")
          |> Map.put(:computed_at, DateTime.utc_now() |> DateTime.to_iso8601())

        json = Jason.encode!(payload, pretty: true)
        File.write!(cache_file, json)
        {:ok, Jason.decode!(json)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compute_snapshot(start_height, end_height) do
    query =
      from t in Transaction,
        where:
          not is_nil(t.block_height) and t.block_height >= ^start_height and
            t.block_height <= ^end_height,
        order_by: [asc: t.block_height, asc: t.inserted_at],
        select: %{
          txid: t.txid,
          inputs: t.inputs,
          outputs: t.outputs,
          block_height: t.block_height
        }

    Repo.transaction(fn ->
      Repo.stream(query, max_rows: 5_000)
      |> Enum.reduce(initial_state(), &process_transaction/2)
      |> finalize_snapshot(start_height, end_height)
    end)
  rescue
    e ->
      Logger.error("Address concentration snapshot failed: #{inspect(e)}")
      {:error, :snapshot_failed}
  end

  defp initial_state do
    %{
      balances: %{},
      utxos: %{},
      total_outputs: 0,
      total_spent: 0,
      tx_count: 0
    }
  end

  defp process_transaction(%{inputs: inputs, outputs: outputs, txid: txid}, state) do
    state
    |> credit_outputs(txid, outputs)
    |> debit_inputs(inputs)
    |> Map.update!(:tx_count, &(&1 + 1))
  rescue
    e ->
      Logger.warning("Skipping transaction #{txid} due to parse error: #{inspect(e)}")
      state
  end

  defp credit_outputs(state, txid, outputs) when is_list(outputs) do
    Enum.with_index(outputs)
    |> Enum.reduce(state, fn {raw_output, index}, acc ->
      with {:ok, output} <- decode_json(raw_output),
           {:ok, address, value_sats} <- extract_output_data(output) do
        utxo_key = utxo_key(txid, index)
        updated_utxos = Map.put(acc.utxos, utxo_key, %{address: address, value: value_sats})
        updated_balances = Map.update(acc.balances, address, value_sats, &(&1 + value_sats))

        acc
        |> Map.put(:utxos, updated_utxos)
        |> Map.put(:balances, updated_balances)
        |> Map.update!(:total_outputs, &(&1 + value_sats))
      else
        _ -> acc
      end
    end)
  end

  defp credit_outputs(state, _txid, _outputs), do: state

  defp debit_inputs(state, inputs) when is_list(inputs) do
    Enum.reduce(inputs, state, fn raw_input, acc ->
      with {:ok, input} <- decode_json(raw_input),
           utxo_txid when is_binary(utxo_txid) <- Map.get(input, "txid"),
           vout when is_integer(vout) <- Map.get(input, "vout"),
           utxo_key <- utxo_key(utxo_txid, vout),
           %{address: address, value: value} <- Map.get(acc.utxos, utxo_key) do
        updated_utxos = Map.delete(acc.utxos, utxo_key)
        updated_balances = Map.update(acc.balances, address, -value, &(&1 - value))

        acc
        |> Map.put(:utxos, updated_utxos)
        |> Map.put(:balances, updated_balances)
        |> Map.update!(:total_spent, &(&1 + value))
      else
        _ -> acc
      end
    end)
  end

  defp debit_inputs(state, _inputs), do: state

  defp finalize_snapshot(state, start_height, end_height) do
    balances =
      state.balances
      |> Enum.filter(fn {_address, satoshis} -> satoshis > 0 end)

    total_satoshis =
      balances
      |> Enum.reduce(0, fn {_address, sat}, acc -> acc + sat end)

    top_addresses =
      balances
      |> Enum.sort_by(fn {_address, sat} -> -sat end)
      |> Enum.take(@top_limit)
      |> Enum.with_index(1)
      |> Enum.map(fn {{address, sat}, rank} ->
        btc = sat / 100_000_000
        percentage = if total_satoshis > 0, do: sat / total_satoshis, else: 0.0

        %{
          rank: rank,
          address: address,
          satoshis: sat,
          btc: Float.round(btc, 8),
          percentage: Float.round(percentage * 100, 6)
        }
      end)

    snapshot = %{
      metadata: %{
        status: "ok",
        start_height: start_height,
        end_height: end_height,
        total_addresses: length(balances),
        total_satoshis: total_satoshis,
        btc_supply: Float.round(total_satoshis / 100_000_000, 8),
        tx_count: state.tx_count,
        utxo_entries: map_size(state.utxos),
        refresh_interval_hours: div(@cache_ttl, 3_600_000)
      },
      top_addresses: top_addresses
    }

    {:ok, snapshot}
  end

  defp decode_json(nil), do: {:error, :empty}
  defp decode_json(value) when is_map(value), do: {:ok, value}

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, result} -> {:ok, result}
      error -> error
    end
  end

  defp decode_json(_), do: {:error, :invalid_json}

  defp extract_output_data(%{"value" => value} = output) when is_number(value) do
    script = Map.get(output, "scriptPubKey", %{})
    addresses = Map.get(script, "addresses", [])

    with true <- is_list(addresses),
         address when is_binary(address) <- List.first(addresses) do
      satoshis = trunc(value * 100_000_000)
      {:ok, address, satoshis}
    else
      _ -> {:error, :no_address}
    end
  end

  defp extract_output_data(_), do: {:error, :invalid_output}

  defp utxo_key(txid, index), do: "#{txid}:#{index}"

  defp current_chain_height do
    case Bitblocks.Chain.get_latest_block() do
      %{height: height} -> height
      _ -> 0
    end
  end
end
