defmodule Bitblocks.Chain.BlockImport do
  @moduledoc """
  Imports raw blocks exported from our node as files, with no node calls.

  Files are named `<height>-<hash>.bin` and hold a serialized block, as
  `scripts/export_blocks` writes them on the node host
  (`bitcoin-cli getblock <hash> 0`). Each one goes through the same path as
  the sync loop (`FetchTransactionsWorker` with `Chain.RawBlock`):

    1. The first 80 bytes must hash to the file's hash and meet their proof
       of work (`HeaderVerifier`).
    2. With no row at that height, the header row is created from those 80
       bytes; a row holding a different block is reported, never replaced.
    3. Every txid is derived from its bytes and the list must rebuild the
       merkleroot; the transactions are stored and the block is marked
       `completed` only once all of them are.

  Importing again skips completed blocks, so it is safe to repeat.

      mix bitblocks.import_blocks ~/blocks/900000-900099
      bin/bitblocks rpc 'Bitblocks.Release.import_raw_blocks("/data/blocks")'
  """

  require Logger

  alias Bitblocks.Chain.{Block, HeaderVerifier, RawBlock}
  alias Bitblocks.Repo
  alias Bitblocks.Workers.FetchTransactionsWorker

  # A file's whole block is stored in one run.
  @run_ms :timer.hours(24)

  @type report :: %{
          completed: [non_neg_integer()],
          already_complete: [non_neg_integer()],
          failed: [{non_neg_integer(), term()}]
        }

  @doc "Imports every `<height>-<hash>.bin` in `dir`, lowest height first."
  @spec import_dir(Path.t()) :: {:ok, report()} | {:error, term()}
  def import_dir(dir) do
    dir = Path.expand(dir)

    if File.dir?(dir) do
      report =
        dir
        |> block_files()
        |> Enum.reduce(%{completed: [], already_complete: [], failed: []}, fn file, acc ->
          case import_file(file, dir) do
            :completed -> Map.update!(acc, :completed, &[file.height | &1])
            :already_complete -> Map.update!(acc, :already_complete, &[file.height | &1])
            {:error, reason} -> Map.update!(acc, :failed, &[{file.height, reason} | &1])
          end
        end)

      {:ok, Map.new(report, fn {k, v} -> {k, Enum.reverse(v)} end)}
    else
      {:error, {:not_a_directory, dir}}
    end
  end

  @doc "The `<height>-<hash>.bin` files in `dir`, by height."
  def block_files(dir) do
    dir
    |> Path.join("*.bin")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Regex.run(~r/^(\d+)-([0-9a-f]{64})\.bin$/, Path.basename(path)) do
        [_, height, hash] -> [%{height: String.to_integer(height), hash: hash, path: path}]
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.height)
  end

  defp import_file(%{height: height, hash: hash, path: path}, dir) do
    case File.read(path) do
      {:ok, bytes} -> import_block(height, hash, bytes, dir)
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  @doc """
  Imports one block's raw bytes at `height` (an upload to
  `POST /admin/blocks/:height`). The hash is taken from the bytes' own
  header, so nothing about the block is trusted from the caller.
  """
  @spec import_bytes(non_neg_integer(), binary()) ::
          {:ok, :completed | :already_complete, String.t()} | {:error, term()}
  def import_bytes(height, bytes) when is_integer(height) and is_binary(bytes) do
    with <<header::binary-80, _::binary>> <- bytes do
      hash = header |> sha256d() |> hex_reversed()
      dir = Path.join(System.tmp_dir!(), "bitblocks-import-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      try do
        File.write!(Path.join(dir, "#{height}-#{hash}.bin"), bytes)

        case import_block(height, hash, bytes, dir) do
          {:error, reason} -> {:error, reason}
          result -> {:ok, result, hash}
        end
      after
        File.rm_rf(dir)
      end
    else
      _ -> {:error, :invalid_block}
    end
  end

  defp import_block(height, hash, bytes, dir) do
    with {:ok, header_bytes, size, num_tx} <- read_header(bytes),
         header = decode_header(header_bytes),
         :ok <- verify_header(header, hash),
         {:ok, block} <- ensure_block(height, hash, header, size, num_tx) do
      if block.sync_state == "completed" do
        :already_complete
      else
        ingest(block, dir)
      end
    else
      {:error, reason} ->
        Logger.warning("BlockImport #{height}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp read_header(bytes) do
    with {:ok, txs} <- RawBlock.parse(bytes),
         <<header::binary-80, _::binary>> <- bytes do
      {:ok, header, byte_size(bytes), length(txs)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_block}
    end
  end

  defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))

  defp verify_header(header, hash) do
    case HeaderVerifier.verify(header, hash) do
      :ok -> :ok
      {:error, :hash_mismatch} -> {:error, :block_hash_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_block(height, hash, header, size, num_tx) do
    case Repo.get_by(Block, height: height) do
      %Block{hash: ^hash} = block ->
        {:ok, block}

      %Block{hash: other} ->
        {:error, {:height_taken, other}}

      nil ->
        %Block{
          hash: hash,
          height: height,
          num_tx: num_tx,
          size: size,
          time: header["time"],
          mediantime: header["time"],
          bits: header["bits"],
          nonce: header["nonce"],
          version: header["version"],
          merkleroot: header["merkleroot"],
          prevblockhash: header["previousblockhash"] || "",
          nextblockhash: "",
          chainwork: "",
          difficulty: "",
          tx: [],
          sync_state: "header_only"
        }
        |> Ecto.Changeset.change(%{})
        |> Repo.insert()
    end
  end

  # The sync loop's own worker, run inline, reading the block from `dir`.
  defp ingest(block, dir) do
    job = %Oban.Job{
      args: %{"block_hash" => block.hash},
      meta: %{"raw_dir" => dir, "run_ms" => @run_ms}
    }

    _ = FetchTransactionsWorker.perform(job)

    case Repo.get(Block, block.id) do
      %Block{sync_state: "completed"} -> :completed
      %Block{} = after_run -> {:error, after_run.tx_sync_error || {:state, after_run.sync_state}}
      nil -> {:error, :block_removed}
    end
  end

  # The 80-byte header as the fields HeaderVerifier and the block row use.
  defp decode_header(
         <<version::little-signed-32, prev::binary-32, merkle::binary-32, time::little-32,
           bits::little-32, nonce::little-32>>
       ) do
    prev_hex = hex_reversed(prev)

    %{
      "version" => version,
      "previousblockhash" => if(prev == <<0::256>>, do: nil, else: prev_hex),
      "merkleroot" => hex_reversed(merkle),
      "time" => time,
      "bits" => bits |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(8, "0"),
      "nonce" => nonce
    }
  end

  defp hex_reversed(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> :binary.list_to_bin()
    |> Base.encode16(case: :lower)
  end
end
