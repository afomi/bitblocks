defmodule Bitblocks.Sync do

  def loady(start, last) do
    skipped_blocks = []

    # Enum.each(start..100_000, fn number ->
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
