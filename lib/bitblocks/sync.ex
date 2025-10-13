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

    # Use verbosity 1 to get tx list with hex, then fetch each tx individually
    # This avoids massive responses for BSV blocks with millions of transactions
    case BitcoinsvCli.getblock(block.hash, 1) do
      {:error, %HTTPoison.Error{reason: :connect_timeout, id: nil}} ->
        IO.puts("Errrrrrr Connect_timeout")

      {:error, %HTTPoison.Error{reason: :closed, id: nil}} ->
        IO.puts("Errrrrrr Closed")

      {:error, %HTTPoison.Error{reason: :timeout, id: nil}} ->
        IO.puts("Errrrrrr Timeout")

      {:error, %HTTPoison.Error{reason: :enetunreach, id: nil}} ->
        IO.puts("Errrrrrr enetunreach")

      block_response ->
        Enum.each(block_response["tx"], fn tx ->
          txid = tx["txid"]
          raw = tx["hex"]

          # For large blocks, we get the hex but need to fetch details for input values
          # Get transaction details to calculate input/output totals
          tx_details = BitcoinsvCli.getrawtransaction(txid, 1)

          {total_input_satoshis, total_output_satoshis} =
            if is_map(tx_details) do
              inputs =
                if tx_details["vin"] do
                  Enum.reduce(tx_details["vin"], 0, fn input, acc ->
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
                if tx_details["vout"] do
                  Enum.reduce(tx_details["vout"], 0, fn output, acc ->
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
            {:ok, _new_tx} ->
              IO.puts("INSERTED transaction from block #{block_height}")

            {:error, changeset} ->
              IO.puts("Failed inserting transaction from block #{block_height}: #{inspect(changeset.errors)}")

            other ->
              IO.puts("Unexpected insert result for block #{block_height}: #{inspect(other)}")
          end
        end)
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
