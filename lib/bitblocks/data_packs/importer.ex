defmodule Bitblocks.DataPacks.Importer do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Bitblocks.{Repo, Chain}

  @block_fields [
    :hash,
    :num_tx,
    :timestamp,
    :bits,
    :chainwork,
    :difficulty,
    :height,
    :mediantime,
    :merkleroot,
    :nextblockhash,
    :prevblockhash,
    :nonce,
    :size,
    :time,
    :version,
    :tx,
    :sync_state,
    :inserted_at,
    :updated_at
  ]

  @transaction_fields [
    :txid,
    :raw,
    :version,
    :block_hash,
    :block_height,
    :inputs,
    :outputs,
    :total_input_satoshis,
    :total_output_satoshis,
    :input_count,
    :output_count,
    :inserted_at,
    :updated_at
  ]

  def import_pack(pack_dir, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 500)
    manifest = read_manifest(pack_dir)

    block_count = import_blocks(pack_dir, chunk_size)
    transaction_count = import_transactions(pack_dir, chunk_size)

    {:ok,
     %{
       manifest: manifest,
       blocks_imported: block_count,
       transactions_imported: transaction_count
     }}
  end

  defp read_manifest(pack_dir) do
    pack_dir
    |> Path.join("manifest.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp import_blocks(pack_dir, chunk_size) do
    blocks_path = Path.join(pack_dir, "blocks.jsonl")

    blocks_path
    |> jsonl_stream()
    |> Stream.map(&normalize_block_record/1)
    |> Stream.chunk_every(chunk_size)
    |> Enum.reduce(0, fn chunk, acc ->
      Repo.insert_all(
        Chain.Block,
        chunk,
        on_conflict: {:replace, @block_fields -- [:height, :inserted_at]},
        conflict_target: :height
      )

      acc + length(chunk)
    end)
  end

  defp import_transactions(pack_dir, chunk_size) do
    transactions_path = Path.join(pack_dir, "transactions.jsonl")

    if File.exists?(transactions_path) do
      transactions_path
      |> jsonl_stream()
      |> Stream.map(&normalize_transaction_record/1)
      |> Stream.chunk_every(chunk_size)
      |> Enum.reduce(0, fn chunk, acc ->
        Repo.insert_all(
          Chain.Transaction,
          chunk,
          on_conflict: {:replace, @transaction_fields -- [:txid, :inserted_at]},
          conflict_target: :txid
        )

        acc + length(chunk)
      end)
    else
      0
    end
  end

  defp jsonl_stream(path) do
    path
    |> File.stream!([], :line)
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&Jason.decode!/1)
  end

  defp normalize_block_record(record) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %{
      hash: record["hash"],
      num_tx: record["num_tx"],
      timestamp: parse_naive_datetime(record["timestamp"]),
      bits: record["bits"],
      chainwork: record["chainwork"],
      difficulty: record["difficulty"],
      height: record["height"],
      mediantime: record["mediantime"],
      merkleroot: record["merkleroot"],
      nextblockhash: record["nextblockhash"],
      prevblockhash: record["prevblockhash"],
      nonce: record["nonce"],
      size: record["size"],
      time: record["time"],
      version: record["version"],
      tx: record["tx"] || [],
      sync_state: record["sync_state"] || "pending",
      inserted_at: now,
      updated_at: now
    }
  end

  defp normalize_transaction_record(record) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %{
      txid: record["txid"],
      raw: record["raw"],
      version: record["version"],
      block_hash: record["block_hash"],
      block_height: record["block_height"],
      inputs: record["inputs"] || [],
      outputs: record["outputs"] || [],
      total_input_satoshis: record["total_input_satoshis"],
      total_output_satoshis: record["total_output_satoshis"],
      input_count: record["input_count"],
      output_count: record["output_count"],
      inserted_at: now,
      updated_at: now
    }
  end

  defp parse_naive_datetime(nil), do: nil

  defp parse_naive_datetime(value) when is_binary(value) do
    {:ok, datetime} = NaiveDateTime.from_iso8601(value)
    datetime
  end
end
