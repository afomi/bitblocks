defmodule Bitblocks.Sync do
  import Ecto.Query, warn: false

  def get_all(range) do
    Enum.each(range, fn block ->
      get(block)
    end)
  end

  def get(block_height) do
    query = from i in Bitblocks.Chain.Block, where: i.height == ^block_height, limit: 1
    block = Bitblocks.Repo.one(query)

    # Block already has txid array from initial sync - use that instead of fetching again
    txids = block.tx || []
    tx_count = length(txids)

    IO.puts("Processing #{tx_count} transactions for block #{block_height}")

    # Use max_transactions_per_block config to limit processing
    max_txs = Application.get_env(:bitblocks, :max_transactions_per_block, 1000)

    txids_to_process =
      if tx_count > max_txs do
        IO.puts("Block #{block_height} has #{tx_count} txs, limiting to first #{max_txs}")
        Enum.take(txids, max_txs)
      else
        txids
      end

    # Fetch transactions in batches using batch RPC
    chunk_size = 100

    txids_to_process
    |> Enum.chunk_every(chunk_size)
    |> Enum.with_index()
    |> Enum.each(fn {chunk, batch_num} ->
      IO.puts(
        "Fetching batch #{batch_num + 1}/#{div(length(txids_to_process), chunk_size) + 1} (#{length(chunk)} txs) for block #{block_height}"
      )

      # Use batch RPC to fetch multiple transactions at once
      case BitcoinsvCli.batch_getrawtransaction(chunk, 1) do
        {:ok, tx_map} ->
          # Process each transaction in the batch
          Enum.each(chunk, fn txid ->
            case Map.get(tx_map, txid) do
              {:error, error} ->
                IO.puts("Failed to fetch tx #{txid}: #{inspect(error)}")

              tx_data when is_map(tx_data) ->
                store_transaction(tx_data, block.hash, block_height)

              nil ->
                IO.puts("No data returned for tx #{txid}")
            end
          end)

        {:error, _reason} ->
          IO.puts("Batch RPC failed for block #{block_height}, falling back to individual calls")

          # Fallback to individual calls
          Enum.each(chunk, fn txid ->
            case BitcoinsvCli.getrawtransaction(txid, 1) do
              tx_data when is_map(tx_data) ->
                store_transaction(tx_data, block.hash, block_height)

              error ->
                IO.puts("Failed to fetch tx #{txid}: #{inspect(error)}")
            end
          end)
      end

      # Small delay between batches to avoid overwhelming the node
      Process.sleep(100)
    end)

    {:ok, length(txids_to_process)}
  end

  defp store_transaction(tx_data, block_hash, block_height) do
    txid = tx_data["txid"]
    raw = tx_data["hex"]

    # Calculate input/output totals from the tx_data we already have
    {total_input_satoshis, total_output_satoshis} =
      if is_map(tx_data) do
        inputs =
          if tx_data["vin"] do
            Enum.reduce(tx_data["vin"], 0, fn input, acc ->
              if Map.has_key?(input, "coinbase") do
                acc
              else
                value = Map.get(input, "value", 0)
                acc + trunc(value * 100_000_000)
              end
            end)
          else
            0
          end

        outputs =
          if tx_data["vout"] do
            Enum.reduce(tx_data["vout"], 0, fn output, acc ->
              value = Map.get(output, "value", 0)
              acc + trunc(value * 100_000_000)
            end)
          else
            0
          end

        {inputs, outputs}
      else
        {0, 0}
      end

    # Decode transaction to get input/output counts
    {input_count, output_count} =
      case BSV.Tx.from_binary(raw, encoding: :hex) do
        {:ok, decoded_tx} ->
          {length(decoded_tx.inputs), length(decoded_tx.outputs)}

        {:error, _} ->
          {0, 0}
      end

    t = %Bitblocks.Chain.Transaction{
      txid: txid,
      raw: raw,
      block_hash: block_hash,
      block_height: block_height,
      inputs: ["tx.inputs"],
      outputs: ["tx.outputs"],
      total_input_satoshis: total_input_satoshis,
      total_output_satoshis: total_output_satoshis,
      input_count: input_count,
      output_count: output_count
    }

    # Insert transaction (with on_conflict to handle duplicates)
    case Bitblocks.Repo.insert(
           Ecto.Changeset.change(t, %{}),
           on_conflict: :nothing,
           conflict_target: :txid
         ) do
      {:ok, _new_tx} ->
        :ok

      {:error, changeset} ->
        IO.puts(
          "Failed inserting transaction #{txid} from block #{block_height}: #{inspect(changeset.errors)}"
        )

        {:error, changeset.errors}

      other ->
        IO.puts("Unexpected insert result for tx #{txid}: #{inspect(other)}")
        {:error, :unexpected}
    end
  end

  # 10:39am Friday Dec 29
  def get_original(block_height) do
    query = from i in Bitblocks.Chain.Block, where: i.height == ^block_height, limit: 1
    block = Bitblocks.Repo.one(query)

    Enum.each(block.tx, fn txid ->
      # Get full transaction details with verbosity 1 for values
      case BitcoinsvCli.getrawtransaction(txid, 1) do
        {:error, _} ->
          IO.puts("SKIPPING #{txid}")

        tx_details ->
          raw = tx_details["hex"]

          # Calculate total input satoshis
          total_input_satoshis =
            if tx_details["vin"] do
              Enum.reduce(tx_details["vin"], 0, fn input, acc ->
                # Coinbase transactions have no value in inputs
                if Map.has_key?(input, "coinbase") do
                  acc
                else
                  # Add the value from this input
                  value = Map.get(input, "value", 0)
                  acc + trunc(value * 100_000_000)
                end
              end)
            else
              0
            end

          # Calculate total output satoshis
          total_output_satoshis =
            if tx_details["vout"] do
              Enum.reduce(tx_details["vout"], 0, fn output, acc ->
                value = Map.get(output, "value", 0)
                acc + trunc(value * 100_000_000)
              end)
            else
              0
            end

          # Decode transaction to get input/output counts
          {input_count, output_count} =
            case BSV.Tx.from_binary(raw, encoding: :hex) do
              {:ok, decoded_tx} ->
                {length(decoded_tx.inputs), length(decoded_tx.outputs)}

              {:error, _} ->
                {0, 0}
            end

          t = %Bitblocks.Chain.Transaction{
            txid: txid,
            raw: raw,
            block_hash: block.hash,
            block_height: block.height,
            inputs: ["tx.inputs"],
            outputs: ["tx.outputs"],
            total_input_satoshis: total_input_satoshis,
            total_output_satoshis: total_output_satoshis,
            input_count: input_count,
            output_count: output_count
          }

          # what else to do to a transaction as it comes in.
          # file explorer options and parser options / responsibilities

          insert =
            t
            |> Ecto.Changeset.change(%{})
            |> Bitblocks.Repo.insert()

          Process.sleep(50)

          IO.puts("last wrote in block #{block_height}")

          case insert do
            {:ok, _block} ->
              "BLOCK INSERT" |> IO.puts()
              # block |> IO.inspect
          end
      end
    end)
  end

  def get_blocks(range) do
    Enum.each(range, fn number ->
      ###
      IO.puts(number)

      block_hash = BitcoinsvCli.getblockhash(number)
      block = BitcoinsvCli.getblock(block_hash)

      %{
        "hash" => hash,
        "num_tx" => num_tx,
        "time" => timestamp,
        "bits" => bits,
        "chainwork" => chainwork,
        "difficulty" => difficulty,
        "height" => height,
        "mediantime" => mediantime,
        "merkleroot" => merkleroot,
        "nonce" => nonce,
        "size" => size,
        "version" => version,
        "tx" => tx
      } = block

      nextblockhash =
        if Map.has_key?(block, "nextblockhash") do
          %{"nextblockhash" => nextblockhash} = block
          nextblockhash
        else
          nil
        end

      prevblockhash =
        if Map.has_key?(block, "previousblockhash") do
          %{"previousblockhash" => prevblockhash} = block
          prevblockhash
        else
          nil
        end

      Process.sleep(250)

      # Extract txids from transaction objects
      txids =
        if is_list(tx) do
          Enum.map(tx, fn
            %{"txid" => txid} -> txid
            txid when is_binary(txid) -> txid
          end)
        else
          []
        end

      b = %Bitblocks.Chain.Block{
        hash: hash,
        num_tx: num_tx,
        time: timestamp,
        bits: bits,
        chainwork: chainwork,
        difficulty: difficulty |> String.Chars.to_string(),
        height: height,
        mediantime: mediantime,
        merkleroot: merkleroot,
        nextblockhash: nextblockhash,
        prevblockhash: prevblockhash,
        nonce: nonce,
        size: size,
        version: version,
        tx: txids
      }

      insert =
        b
        |> Ecto.Changeset.change(%{})
        |> Bitblocks.Repo.insert()

      case insert do
        {:ok, _block} ->
          ###
          IO.puts(number)
          ###
          IO.puts("DONE")
          ###
          IO.puts("-------------")

        {nil} ->
          ###
          IO.puts(number)
          ###
          IO.puts("DONE")
          ###
          IO.puts("-------------")
      end
    end)
  end
end
