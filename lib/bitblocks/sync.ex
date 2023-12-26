defmodule Bitblocks.Chain.Block do

  def loady(start) do
    Enum.each(start..100_000, fn number ->
      IO.puts(number) ###

      block_hash = BitcoinsvCli.getblockhash(number)
      block = BitcoinsvCli.getblock(block_hash)
      block |> IO.inspect ####

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

      Process.sleep(750)

      b = %Bitblocks.Block{
        hash: hash,
        num_tx: num_tx,
        time: timestamp,
        bits: bits,
        chainwork: chainwork,
        difficulty: difficulty,
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

      {:ok, block } = b
        |> Ecto.Changeset.change(%{})
        |> Bitblocks.Repo.insert()

      IO.puts(number) ###
      IO.puts("DONE") ###
      IO.puts("-------------") ###
    end)
  end

end
