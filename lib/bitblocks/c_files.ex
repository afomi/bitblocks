defmodule Bitblocks.CFiles do
  @moduledoc """
  The C:// index (https://github.com/afomi/bitblocks/issues/147): a file's
  C:// address is the sha256 of its bytes (unwriter's C://, 2019), and the
  `c_files` table maps it to where those bytes are on chain. Two kinds:

    * `"b"`: a B:// output, one row per file output of a tx tagged `B://`,
      written by the `index_c_files` tx step at ingest;
    * `"bcat"`: a BCat file (https://github.com/afomi/bitblocks/issues/155),
      split across the chunk txs its head names. Its address is the sha256
      of the whole file, so it is indexed only once the file has been
      assembled from its chunks (`Bitblocks.Bcat.assemble/1`: each chunk
      from our database or tx store, else WhatsOnChain as a raw tx checked
      against its txid). That reads up to 256 chunks and 32 MB, so the step
      assembles nothing inline: it enqueues `Workers.CFileBcatWorker` on
      the low-priority `:derived` queue, and `index_bcat/3` does the work.
      A head we can't assemble gets no row; its reason is kept in
      `c_file_misses` (`CFiles.Miss`), never a guessed address.

  Txs stored before the step are filled by its backfill
  (`Chain.TxPipeline.CFilesBackfill`). B:// and BCat txs are rare, so the
  tables stay small, and filling them never touches `transactions`.

  `resolve/1` is what `GET /c/:sha256` serves: the bytes are read again (a
  B:// output from its tx, `TxStore.raw_or_fetch/1`; a BCat file assembled
  again) and hashed again, and only bytes that match the address are
  returned. WhatsOnChain only ever supplies raw txs, checked against their
  txids. It never answers whether a hash exists: only this table does, and
  `coverage/0` says how far it reaches.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Bitcom.BFile
  alias Bitblocks.CFiles.{CFile, Miss}
  alias Bitblocks.Chain.{Block, RawTx, Transaction}
  alias Bitblocks.Derivations.Run
  alias Bitblocks.{Bcat, Repo, SyncProgress, TxStore}

  # v1: B:// outputs. v2: BCat files too (#155). A B:// row v1 wrote is the
  # row v2 would write, so the backfill leaves it as it is.
  @version 2
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
  True when a stored tx is tagged BCat (an output starts with the BCat
  prefix): a head whose file `index_bcat/3` may assemble.
  """
  @spec bcat_candidate?(Transaction.t()) :: boolean()
  def bcat_candidate?(%Transaction{protocols: protocols}) when is_list(protocols),
    do: "BCat" in protocols

  def bcat_candidate?(_tx), do: false

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
            kind: "b",
            chunks: nil,
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

  A BCat head writes nothing here: it enqueues its assembly
  (`enqueue_bcat/2`), which runs once the tx's database transaction has
  committed.
  """
  @spec index(Transaction.t(), Block.t() | nil) :: non_neg_integer()
  def index(%Transaction{txid: txid, raw: raw} = tx, block) do
    if bcat_candidate?(tx), do: enqueue_bcat(txid, block && block.height)
    if candidate?(tx), do: write(rows(txid, raw, block && block.height)), else: 0
  end

  @doc """
  Enqueues the assembly of the BCat file this head names
  (`Workers.CFileBcatWorker`, queue `:derived`), unique on the head txid.
  """
  @spec enqueue_bcat(String.t(), integer() | nil) :: :ok
  def enqueue_bcat(txid, height) do
    %{txid: txid, block_height: height}
    |> Bitblocks.Workers.CFileBcatWorker.new()
    |> Oban.insert!()

    :ok
  end

  @typedoc "Why a BCat head stays unindexed (`c_file_misses.reason`)."
  @type miss_reason ::
          :missing_chunks | :unavailable | :too_large | :no_chunks | :not_bcat | :head_not_found

  @doc """
  Assembles the BCat file the head `txid` names, mined at `height`, and
  indexes it by the sha256 of the whole file:

    * `{:ok, row}`: assembled from chunks each checked against its txid,
      written to `c_files` (kind `"bcat"`), and any earlier miss cleared;
    * `{:error, reason}`: not indexed; the reason is kept in
      `c_file_misses`, with the missing chunk txids for `:missing_chunks`.
      `:unavailable` (a source couldn't be asked just now) is the one
      worth retrying.

  Options: `apply: false` assembles and writes nothing.
  """
  @spec index_bcat(String.t(), integer() | nil, keyword()) ::
          {:ok, map()} | {:error, miss_reason()}
  def index_bcat(txid, height, opts \\ []) do
    apply? = Keyword.get(opts, :apply, true)

    case Bcat.assemble(txid) do
      {:ok, file} ->
        row = bcat_row(txid, height, file)

        if apply? do
          write([row])
          Repo.delete_all(from(m in Miss, where: m.txid == ^txid))
        end

        {:ok, row}

      {:error, error} ->
        {reason, missing} = miss_reason(error)
        if apply?, do: record_miss(txid, height, reason, missing)
        {:error, reason}
    end
  end

  defp miss_reason({:missing, txids}), do: {:missing_chunks, txids}
  defp miss_reason({:unavailable, _txids}), do: {:unavailable, []}
  defp miss_reason({:fetch_failed, _}), do: {:unavailable, []}
  defp miss_reason(:not_found), do: {:head_not_found, []}

  defp miss_reason(reason) when reason in [:too_large, :no_chunks, :not_bcat],
    do: {reason, []}

  @doc "The `c_files` row for a BCat file `Bcat.assemble/1` assembled."
  @spec bcat_row(String.t(), integer() | nil, map()) :: map()
  def bcat_row(txid, height, file) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      sha256: :crypto.hash(:sha256, file.data),
      txid: txid,
      vout: file.vout,
      block_height: height,
      kind: "bcat",
      chunks: file.chunks,
      media_type: file.mime,
      encoding: file.charset,
      filename: file.filename,
      size: byte_size(file.data),
      version: @version,
      inserted_at: now,
      updated_at: now
    }
  end

  defp record_miss(txid, height, reason, missing) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      Miss,
      [
        %{
          txid: txid,
          block_height: height,
          kind: "bcat",
          reason: Atom.to_string(reason),
          missing_chunks: missing,
          version: @version,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:block_height, :reason, :missing_chunks, :version, :updated_at]},
      conflict_target: [:txid]
    )

    Logger.info("C:// BCat head #{txid} not indexed: #{reason}")
  end

  @doc "True when the BCat head `txid` already has its `c_files` row."
  @spec bcat_indexed?(String.t()) :: boolean()
  def bcat_indexed?(txid),
    do: Repo.exists?(from(c in CFile, where: c.txid == ^txid and c.kind == "bcat"))

  @doc ~S'The BCat heads not indexed, counted by reason: `%{"missing_chunks" => 2}`.'
  @spec misses_by_reason() :: %{String.t() => non_neg_integer()}
  def misses_by_reason do
    from(m in Miss, group_by: m.reason, select: {m.reason, count()})
    |> Repo.all()
    |> Map.new()
  end

  @doc "The BCat heads not indexed, newest block first, at most `limit`."
  @spec misses(pos_integer()) :: [Miss.t()]
  def misses(limit \\ 50) do
    Repo.all(
      from(m in Miss, order_by: [desc_nulls_last: m.block_height, asc: m.txid], limit: ^limit)
    )
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

  @doc """
  Deletes the rows, and the recorded misses, of txs that are no longer
  stored (a reorg). Returns how many rows it deleted.
  """
  @spec delete_txids([String.t()]) :: non_neg_integer()
  def delete_txids([]), do: 0

  def delete_txids(txids) do
    {n, _} = Repo.delete_all(from(c in CFile, where: c.txid in ^txids))
    Repo.delete_all(from(m in Miss, where: m.txid in ^txids))
    n
  end

  @doc """
  Moves the rows (and misses) of txs a reorg moved to another block to its
  height. Returns how many rows it moved.
  """
  @spec moved([String.t()], integer() | nil) :: non_neg_integer()
  def moved([], _height), do: 0

  def moved(txids, height) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {n, _} =
      Repo.update_all(from(c in CFile, where: c.txid in ^txids),
        set: [block_height: height, updated_at: now]
      )

    Repo.update_all(from(m in Miss, where: m.txid in ^txids),
      set: [block_height: height, updated_at: now]
    )

    n
  end

  @doc """
  The stored files with this address (32 raw bytes), B:// outputs and BCat
  files alike, oldest block first, at most #{@locations_limit}.
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
  the oldest stored copy whose bytes hash to it, read now (a B:// output
  from its tx, a BCat file assembled again from its chunks).

    * `{:error, :not_indexed}`: no row has this address (see `coverage/0`);
    * `{:error, :mismatch}`: rows have it, but no copy's bytes hash to it,
      so nothing is served;
    * `{:error, :unavailable}`: a copy's tx, or a chunk of it, couldn't be
      fetched just now.
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

  defp content(%CFile{kind: "bcat", txid: txid}) do
    case Bcat.assemble(txid) do
      {:ok, file} -> {:ok, file.data}
      {:error, {:unavailable, _txids}} -> {:error, {:fetch_failed, :chunks}}
      {:error, reason} -> {:error, reason}
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
  nil until a backfill covers the chain from block 0), `complete_through`,
  the height the sync is complete through, and `bcat_unassembled`, how many
  BCat heads we know of couldn't be assembled, so their addresses aren't in
  the index.
  """
  @spec coverage() :: %{
          indexed_through_height: non_neg_integer() | nil,
          complete_through: integer() | nil,
          bcat_unassembled: non_neg_integer()
        }
  def coverage do
    complete_through = SyncProgress.snapshot().overview.complete_through

    %{
      indexed_through_height: indexed_through(complete_through),
      complete_through: complete_through,
      bcat_unassembled: Repo.aggregate(Miss, :count)
    }
  end

  @doc """
  The highest height H such that the applied `c_files` backfill runs at the
  current version cover every height 0..H, capped at `complete_through`.
  Nil when they don't reach block 0. The step indexes blocks synced since
  it shipped as well, but only a run says a range is whole, so this may
  read lower than the truth, never higher. A run at v1 indexed only B://
  files, so it doesn't count.
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
      kind: c.kind,
      txid: c.txid,
      vout: c.vout,
      block_height: c.block_height,
      media_type: c.media_type,
      encoding: c.encoding,
      filename: c.filename,
      size: c.size,
      chunks: c.chunks,
      b_url: if(c.kind == "b", do: "/b/#{c.txid}"),
      bcat_url: if(c.kind == "bcat", do: "/content/bcat/#{c.txid}")
    }
  end
end
