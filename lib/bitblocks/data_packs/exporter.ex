defmodule Bitblocks.DataPacks.Exporter do
  @moduledoc false

  alias Bitblocks.DataPacks.{Manifest, Spec}

  def export_range(%Spec{} = spec, opts \\ []) do
    rpc_module = Keyword.get(opts, :rpc_module, BitcoinsvCli)

    output_dir = Spec.output_dir(spec)
    File.mkdir_p!(output_dir)

    blocks_path = Path.join(output_dir, "blocks.jsonl")
    transactions_path = Path.join(output_dir, "transactions.jsonl")

    File.rm(blocks_path)
    maybe_remove_transactions_file(spec, transactions_path)

    {block_count, transaction_count} =
      blocks_path
      |> File.open!([:write, :utf8])
      |> then(fn blocks_io ->
        tx_io = maybe_open_transactions_io(spec, transactions_path)

        try do
          do_export_range(spec, rpc_module, blocks_io, tx_io)
        after
          File.close(blocks_io)
          if tx_io, do: File.close(tx_io)
        end
      end)

    manifest =
      Manifest.build(spec, %{
        block_count: block_count,
        transaction_count: transaction_count
      })

    manifest_path = Path.join(output_dir, "manifest.json")
    File.write!(manifest_path, Jason.encode_to_iodata!(manifest, pretty: true))

    {:ok, %{manifest: manifest, output_dir: output_dir}}
  end

  defp do_export_range(spec, rpc_module, blocks_io, tx_io) do
    spec.start_height..spec.end_height
    |> Enum.chunk_every(spec.block_chunk_size)
    |> Enum.reduce({0, 0}, fn heights, {block_count, transaction_count} ->
      {:ok, hashes} = rpc_module.batch_getblockhash(heights)

      {new_blocks, new_transactions} =
        heights
        |> Enum.reduce({block_count, transaction_count}, fn height, {blocks_acc, txs_acc} ->
          hash = Map.fetch!(hashes, height)
          block = rpc_module.getblock(hash, 1)
          block_record = block_record(block, spec.fidelity)

          IO.binwrite(blocks_io, Jason.encode_to_iodata!(block_record))
          IO.binwrite(blocks_io, "\n")

          tx_count =
            case spec.fidelity do
              :full ->
                exported =
                  export_transactions(
                    block["tx"] || [],
                    block,
                    spec,
                    rpc_module,
                    tx_io
                  )

                txs_acc + exported

              _ ->
                txs_acc
            end

          {blocks_acc + 1, tx_count}
        end)

      {new_blocks, new_transactions}
    end)
  end

  defp export_transactions([], _block, _spec, _rpc_module, _tx_io), do: 0

  defp export_transactions(txids, block, spec, rpc_module, tx_io) do
    txids
    |> Enum.chunk_every(spec.tx_chunk_size)
    |> Enum.reduce(0, fn chunk, acc ->
      {:ok, tx_map} = rpc_module.batch_getrawtransaction(chunk, 1)

      exported =
        Enum.reduce(chunk, 0, fn txid, tx_acc ->
          tx = Map.fetch!(tx_map, txid)
          tx_record = transaction_record(tx, block)

          IO.binwrite(tx_io, Jason.encode_to_iodata!(tx_record))
          IO.binwrite(tx_io, "\n")

          tx_acc + 1
        end)

      acc + exported
    end)
  end

  defp maybe_open_transactions_io(%Spec{fidelity: :full}, transactions_path) do
    File.open!(transactions_path, [:write, :utf8])
  end

  defp maybe_open_transactions_io(_spec, _transactions_path), do: nil

  defp maybe_remove_transactions_file(%Spec{fidelity: :full}, transactions_path) do
    File.rm(transactions_path)
  end

  defp maybe_remove_transactions_file(_spec, _transactions_path), do: :ok

  defp block_record(block, fidelity) do
    %{
      "hash" => block["hash"],
      "num_tx" => block["num_tx"],
      "timestamp" => block_timestamp(block["time"]),
      "bits" => block["bits"],
      "chainwork" => block["chainwork"],
      "difficulty" => to_string(block["difficulty"] || ""),
      "height" => block["height"],
      "mediantime" => block["mediantime"],
      "merkleroot" => block["merkleroot"],
      "nextblockhash" => block["nextblockhash"],
      "prevblockhash" => block["previousblockhash"] || block["prevblockhash"],
      "nonce" => block["nonce"],
      "size" => block["size"],
      "time" => block["time"],
      "version" => block["version"],
      "tx" => tx_payload(block["tx"] || [], fidelity),
      "sync_state" => sync_state_for(fidelity)
    }
  end

  defp transaction_record(tx, block) do
    {total_input_satoshis, total_output_satoshis} = satoshi_totals(tx)
    vin = tx["vin"] || []
    vout = tx["vout"] || []

    %{
      "txid" => tx["txid"],
      "raw" => tx["hex"],
      "version" => to_string(tx["version"] || ""),
      "block_hash" => block["hash"],
      "block_height" => block["height"],
      "inputs" => Enum.map(vin, &Jason.encode!/1),
      "outputs" => Enum.map(vout, &Jason.encode!/1),
      "total_input_satoshis" => total_input_satoshis,
      "total_output_satoshis" => total_output_satoshis,
      "input_count" => length(vin),
      "output_count" => length(vout)
    }
  end

  defp satoshi_totals(tx) do
    vin_total =
      tx["vin"]
      |> List.wrap()
      |> Enum.reduce(0, fn input, acc ->
        if Map.has_key?(input, "coinbase") do
          acc
        else
          value = Map.get(input, "value", 0)
          acc + trunc(value * 100_000_000)
        end
      end)

    vout_total =
      tx["vout"]
      |> List.wrap()
      |> Enum.reduce(0, fn output, acc ->
        value = Map.get(output, "value", 0)
        acc + trunc(value * 100_000_000)
      end)

    {vin_total, vout_total}
  end

  defp block_timestamp(nil), do: nil

  defp block_timestamp(unix_time) do
    unix_time
    |> DateTime.from_unix!()
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
  end

  defp tx_payload(_txids, :headers_only), do: []
  defp tx_payload(txids, _fidelity), do: txids

  defp sync_state_for(:headers_only), do: "header_only"
  defp sync_state_for(:index_only), do: "header_synced"
  defp sync_state_for(:full), do: "completed"
end
