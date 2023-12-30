defmodule Bitblocks.Sync do
  require IEx

  import Ecto.Query, warn: false
  alias Bitblocks.Repo

  def get_all(range) do
    Enum.each(range, fn block ->
      get(block)
    end)
  end

  def get(block_height) do

    # blocks = Bitblocks.Repo.all(query)
    query = from i in Bitblocks.Block,
        where: (i.height == ^block_height), limit: 1
    block = Bitblocks.Repo.one(query)

    case BitcoinsvCli.getblock(block.hash, level = 2) do
      {:error, %HTTPoison.Error{reason: :connect_timeout, id: nil}} ->
        IO.puts "Errrrrrr Connect_timeout"

      {:error, %HTTPoison.Error{reason: :closed, id: nil}} ->
        IO.puts "Errrrrrr Closed"

      {:error, %HTTPoison.Error{reason: :timeout, id: nil}} ->
        IO.puts "Errrrrrr Timeout"

      {:error, %HTTPoison.Error{reason: :enetunreach, id: nil}} ->
        IO.puts "Errrrrrr enetunreach"

      block_response ->
        Enum.each(block_response["tx"], fn tx ->

          txid = tx["txid"]
          raw = tx["hex"]

            t = %Bitblocks.Transaction{
              txid: txid,
              raw: raw,
              block_hash: block.hash,
              inputs: ["tx.inputs"],
              outputs: ["tx.outputs"]
            }

            # what else to do to a transaction as it comes in.
            # file explorer options and parser options / responsibilities

            insert = t
                |> Ecto.Changeset.change(%{})
                |> Bitblocks.Repo.insert()

            Process.sleep(250)

            IO.puts "last wrote in block #{block_height}"

            case insert do
              {:ok, block} ->
                "BLOCK INSERT" |> IO.puts
                # block |> IO.inspect
            end


        end)
    end


  end

  def get_original(block_height) do # 10:39am Friday Dec 29
    query = from i in Bitblocks.Block,
        where: (i.height == ^block_height), limit: 1
    block = Bitblocks.Repo.one(query)


    Enum.each(block.tx, fn txid ->

      case BitcoinsvCli.getrawtransaction(txid) do

        {:error, _} ->
          IO.puts("SKIPPING #{txid}")

        raw ->
          BitcoinsvCli.decoderawtransaction(raw)

          t = %Bitblocks.Transaction{
            txid: txid,
            raw: raw,
            block_hash: block.hash,
            inputs: ["tx.inputs"],
            outputs: ["tx.outputs"]
          }

          # what else to do to a transaction as it comes in.
          # file explorer options and parser options / responsibilities

          insert = t
              |> Ecto.Changeset.change(%{})
              |> Bitblocks.Repo.insert()

          Process.sleep(250)

          IO.puts "last wrote in block #{block_height}"

          case insert do
            {:ok, block} ->
              "BLOCK INSERT" |> IO.puts
              # block |> IO.inspect
          end
      end

    end)

  end

  def loady(start, last) do
    skipped_blocks = []

    Enum.each(start..last, fn number ->
      IO.puts(number) ###

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
        "tx" => tx,
      } = block

      nextblockhash = ""
      prevblockhash = ""
      nextblockhash = if Map.has_key?(block, "nextblockhash") do
        %{ "nextblockhash" => nextblockhash } = block
        nextblockhash
      end
      prevblockhash = if Map.has_key?(block, "previousblockhash") do
        %{ "previousblockhash" => prevblockhash } = block
        prevblockhash
      end


      # Process.sleep(750)

      b = %Bitblocks.Block{
        hash: hash,
        num_tx: num_tx,
        time: timestamp,
        bits: bits,
        chainwork: chainwork,
        difficulty: difficulty / 1.0,
        height: height,
        mediantime: mediantime,
        merkleroot: merkleroot,
        nextblockhash: nextblockhash,
        prevblockhash: prevblockhash,
        nonce: nonce,
        size: size,
        version: version,
        tx: tx,
      }

      # Skip blocks that have more than 220,000 transactions (which is a lot after 2022),
      # because that many 64-character txid's exceeds Mongodb's 16MB limit per field
      #
      # TODO: explore another datastore, like RocksDB or PostgreSQL
      if num_tx < 220_000 do

        insert = b
          |> Ecto.Changeset.change(%{})
          |> Bitblocks.Repo.insert()

        case insert do
          {:ok, block } ->
            IO.puts(number) ###
            IO.puts("DONE") ###
            IO.puts("-------------") ###

          {nil} ->
            IO.puts(number) ###
            IO.puts("DONE") ###
            IO.puts("-------------") ###
        end

      else
        skipped_blocks ++ [height]
        skipped_blocks |> IO.puts
      end

    end)
  end

end
