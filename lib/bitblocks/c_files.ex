defmodule Bitblocks.CFiles do
  @moduledoc """
  The C:// index (https://github.com/afomi/bitblocks/issues/147): a file's
  C:// address is the sha256 of its bytes (unwriter's C://, 2019), and the
  `c_files` table maps it to the B:// outputs that carry those bytes.

  Written by the `index_c_files` tx step for txs tagged `B://` at ingest,
  and by its backfill (`Chain.TxPipeline.CFilesBackfill`) for txs stored
  before the step. B:// files are rare, so the table stays small, and
  filling it never touches `transactions`.

  `resolve/1` is what `GET /c/:sha256` serves: the bytes are read from the
  tx again (`TxStore.raw_or_fetch/1`: our database or tx store, else
  WhatsOnChain checked against the txid) and hashed again, and only bytes
  that match the address are returned. WhatsOnChain never answers whether
  a hash exists: only this table does, and `coverage/0` says how far it
  reaches.
  """

  import Ecto.Query

  alias Bitblocks.Bitcom.BFile
  alias Bitblocks.CFiles.CFile
  alias Bitblocks.Chain.{Block, RawTx, Transaction}
  alias Bitblocks.Derivations.Run
  alias Bitblocks.{Repo, SyncProgress, TxStore}

  @version 1
  # How many stored copies of one file `locations/1` lists, and `resolve/1`
  # tries before giving up.
  @locations_limit 50
  @resolve_tries 5

  @doc "The index_c_files step's version, stamped on each row."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  A C:// address as given (64 hex characters, any case) as 32 raw bytes;
  `:error` for anything else.
  """
  @spec parse_address(String.t()) :: {:ok, binary()} | :error
  def parse_address(hex) when is_binary(hex) do
    if hex =~ ~r/\A[0-9a-fA-F]{64}\z/, do: Base.decode16(hex, case: :mixed), else: :error
  end

  def parse_address(_hex), do: :error

  @doc "True when a stored tx is tagged B:// and has bytes to read."
  @spec candidate?(Transaction.t()) :: boolean()
  def candidate?(%Transaction{raw: raw, protocols: protocols})
      when is_binary(raw) and raw != "" and is_list(protocols),
      do: "B://" in protocols

  def candidate?(_tx), do: false

  @doc """
  The rows for a tx's B:// files: hex `raw`, mined at `height` (nil when
  unknown). `[]` for a tx with no B:// file or that doesn't decode.
  """
  @spec rows(String.t(), String.t(), integer() | nil) :: [map()]
  def rows(txid, raw, height) do
    case RawTx.parse(raw) do
      {:ok, tx} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        for file <- BFile.parse_all(tx) do
          %{
            sha256: :crypto.hash(:sha256, file.content),
            txid: txid,
            vout: file.vout,
            block_height: height,
            media_type: file.media_type,
            encoding: file.encoding,
            filename: file.filename,
            size: byte_size(file.content),
            version: @version,
            inserted_at: now,
            updated_at: now
          }
        end

      {:error, _} ->
        []
    end
  end

  @doc """
  Writes a stored tx's B:// files, mined in `block`. Idempotent on (txid,
  vout): a rerun rewrites the same rows. Returns how many it wrote; 0 for a
  tx that isn't a candidate, at no cost.
  """
  @spec index(Transaction.t(), Block.t() | nil) :: non_neg_integer()
  def index(%Transaction{txid: txid, raw: raw} = tx, block) do
    if candidate?(tx), do: write(rows(txid, raw, block && block.height)), else: 0
  end

  @doc "Inserts rows, replacing a row already stored for the same output."
  @spec write([map()]) :: non_neg_integer()
  def write([]), do: 0

  def write(rows) do
    rows
    |> Enum.chunk_every(2_000)
    |> Enum.reduce(0, fn batch, acc ->
      {count, _} =
        Repo.insert_all(
          CFile,
          batch,
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: [:txid, :vout]
        )

      acc + count
    end)
  end

  @doc "Deletes the rows of txs that are no longer stored (a reorg)."
  @spec delete_txids([String.t()]) :: non_neg_integer()
  def delete_txids([]), do: 0

  def delete_txids(txids) do
    {n, _} = Repo.delete_all(from(c in CFile, where: c.txid in ^txids))
    n
  end

  @doc "Moves the rows of txs a reorg moved to another block to its height."
  @spec moved([String.t()], integer() | nil) :: non_neg_integer()
  def moved([], _height), do: 0

  def moved(txids, height) do
    {n, _} =
      Repo.update_all(from(c in CFile, where: c.txid in ^txids),
        set: [block_height: height, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

    n
  end

  @doc """
  The stored outputs that carry the file with this address (32 raw bytes),
  oldest block first, at most #{@locations_limit}.
  """
  @spec locations(binary()) :: [CFile.t()]
  def locations(sha256) when byte_size(sha256) == 32 do
    Repo.all(
      from(c in CFile,
        where: c.sha256 == ^sha256,
        order_by: [asc_nulls_last: c.block_height, asc: c.txid, asc: c.vout],
        limit: @locations_limit
      )
    )
  end

  @doc """
  The file with this address (32 raw bytes): `{:ok, location, content}`,
  the oldest stored copy whose bytes hash to it, read from its tx now.

    * `{:error, :not_indexed}`: no row has this address (see `coverage/0`);
    * `{:error, :mismatch}`: rows have it, but no copy's bytes hash to it,
      so nothing is served;
    * `{:error, :unavailable}`: a copy's tx couldn't be fetched just now.
  """
  @spec resolve(binary()) ::
          {:ok, CFile.t(), binary()} | {:error, :not_indexed | :mismatch | :unavailable}
  def resolve(sha256) when byte_size(sha256) == 32 do
    case locations(sha256) do
      [] -> {:error, :not_indexed}
      rows -> rows |> Enum.take(@resolve_tries) |> first_match(sha256, :mismatch)
    end
  end

  defp first_match([], _sha256, error), do: {:error, error}

  defp first_match([row | rest], sha256, error) do
    case content(row) do
      {:ok, content} ->
        if :crypto.hash(:sha256, content) == sha256,
          do: {:ok, row, content},
          else: first_match(rest, sha256, error)

      {:error, {:fetch_failed, _}} ->
        first_match(rest, sha256, :unavailable)

      {:error, _} ->
        first_match(rest, sha256, error)
    end
  end

  defp content(%CFile{txid: txid, vout: vout}) do
    with {:ok, bytes} <- TxStore.raw_or_fetch(txid),
         {:ok, tx} <- RawTx.parse(Base.encode16(bytes)),
         {:ok, file} <- BFile.parse_output(tx, vout) do
      {:ok, file.content}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :no_file}
    end
  end

  @doc """
  How far the index reaches: `indexed_through_height` (`indexed_through/1`,
  nil until a backfill covers the chain from block 0) and
  `complete_through`, the height the sync is complete through.
  """
  @spec coverage() :: %{
          indexed_through_height: non_neg_integer() | nil,
          complete_through: integer() | nil
        }
  def coverage do
    complete_through = SyncProgress.snapshot().overview.complete_through

    %{
      indexed_through_height: indexed_through(complete_through),
      complete_through: complete_through
    }
  end

  @doc """
  The highest height H such that the applied `c_files` backfill runs at the
  current version cover every height 0..H, capped at `complete_through`.
  Nil when they don't reach block 0. The step indexes blocks synced since
  it shipped as well, but only a run says a range is whole, so this may
  read lower than the truth, never higher.
  """
  @spec indexed_through(integer() | nil) :: non_neg_integer() | nil
  def indexed_through(complete_through) when is_integer(complete_through) do
    through =
      from(r in Run,
        where:
          r.derivation == "c_files" and r.applied and r.outcome in ["ok", "halted"] and
            r.version == ^@version and not is_nil(r.from_height) and not is_nil(r.to_height),
        order_by: [asc: r.from_height, desc: r.to_height],
        select: {r.from_height, r.to_height}
      )
      |> Repo.all()
      |> Enum.reduce_while(-1, fn {from, to}, through ->
        if from <= through + 1, do: {:cont, max(through, to)}, else: {:halt, through}
      end)
      |> min(complete_through)

    if through >= 0, do: through
  end

  def indexed_through(_complete_through), do: nil

  @doc "A row as the API shows it."
  @spec public(CFile.t()) :: map()
  def public(%CFile{} = c) do
    %{
      sha256: Base.encode16(c.sha256, case: :lower),
      txid: c.txid,
      vout: c.vout,
      block_height: c.block_height,
      media_type: c.media_type,
      encoding: c.encoding,
      filename: c.filename,
      size: c.size,
      b_url: "/b/#{c.txid}"
    }
  end
end
