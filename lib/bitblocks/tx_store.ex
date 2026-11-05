defmodule Bitblocks.TxStore do
  @moduledoc """
  The blob store for raw transaction bytes, keyed by txid.

  Transactions are immutable and content-addressed, so commodity object
  storage behind one CDN URL is enough: `raw/{txid}` holds the tx's exact
  bytes (binary, not hex), written once and served `immutable`.

  Guarantees:

    * **Only true bytes are written.** `put/2` refuses bytes that don't hash to
      the txid.
    * **A write is confirmed, not assumed.** `store/1` reads the object back
      and compares sizes before setting `transactions.blob_stored_at`; a
      failed or unverified write leaves it null and returns the error.
    * **Reads don't care where the bytes live.** `raw/1` takes the database's
      `raw` column while it still holds it, then the blob store: the tx's own
      object `raw/{txid}`, or a ranged read of its block's object
      `blocks/<height>-<hash>.bin` (`Bitblocks.TxStore.BlockObject`) at the
      row's `raw_offset` and `raw_length`. Store bytes are served only if they
      hash to the txid. So large payloads can later leave Postgres without
      changing callers.

  Adapters (`config :bitblocks, Bitblocks.TxStore, adapter: …`):
  `Bitblocks.TxStore.S3` in prod (bucket `AWS_S3_BUCKET_TXS`, CDN
  `CDN_BASE_URL`), `Bitblocks.TxStore.Local` in dev and test.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.Transaction
  alias Bitblocks.Repo

  @callback put(key :: String.t(), bytes :: binary()) :: :ok | {:error, term()}
  @callback get(key :: String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  @callback size(key :: String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found | term()}
  @callback get_range(key :: String.t(), offset :: non_neg_integer(), length :: pos_integer()) ::
              {:ok, binary()} | {:error, :not_found | term()}
  @callback public_url(key :: String.t()) :: String.t() | nil
  @callback ready?() :: :ok | {:error, term()}

  @doc "The object key for a txid."
  def key(txid), do: "raw/#{txid}"

  @doc """
  Writes `bytes` for `txid` if they hash to it. Write-once: an existing object
  of the same size is left alone.
  """
  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(txid, bytes) when is_binary(txid) and is_binary(bytes) do
    cond do
      txid(bytes) != txid ->
        {:error, :bytes_do_not_hash_to_txid}

      adapter().size(key(txid)) == {:ok, byte_size(bytes)} ->
        :ok

      true ->
        adapter().put(key(txid), bytes)
    end
  end

  @doc """
  Copies a stored tx's bytes into the blob store and, once read back and
  verified, sets `blob_stored_at`. Idempotent.
  """
  @spec store(String.t()) :: :ok | {:error, term()}
  def store(txid) do
    with {:ok, bytes} <- db_bytes(txid),
         :ok <- put(txid, bytes),
         {:ok, size} when size == byte_size(bytes) <- adapter().size(key(txid)) do
      Repo.update_all(
        from(t in Transaction, where: t.txid == ^txid and is_nil(t.blob_stored_at)),
        set: [blob_stored_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      :ok
    else
      {:ok, size} ->
        Logger.error("TxStore: #{txid} read back #{size} bytes; expected another size")
        {:error, :size_mismatch}

      {:error, reason} = error ->
        Logger.warning("TxStore: could not store #{txid}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Raw bytes for a txid, from the first place that has them: the database's
  `raw` column; the tx's own object `raw/{txid}` (read first when the row is
  stamped `blob_stored_at`, and for a txid we hold no row for); a ranged read
  of its block's object, when the block is stamped `raw_object_stored_at` and
  the row has `raw_offset` and `raw_length`. Bytes from the store must hash to
  the txid, or it's `{:error, :bytes_do_not_hash_to_txid}`.
  """
  @spec raw(String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  def raw(txid) do
    case location(txid) do
      %{raw: raw} when is_binary(raw) and raw != "" ->
        decode_hex(raw)

      %{blob_stored_at: nil, block_object: true} = loc ->
        from_block_object(txid, loc)

      %{block_object: true} = loc ->
        with {:error, _} <- from_tx_object(txid), do: from_block_object(txid, loc)

      _ ->
        from_tx_object(txid)
    end
  end

  defp from_tx_object(txid) do
    with {:ok, bytes} <- adapter().get(key(txid)) do
      verified(txid, bytes)
    end
  end

  defp from_block_object(txid, loc) do
    key = Bitblocks.TxStore.BlockObject.key(loc.height, loc.block_hash)

    with {:ok, bytes} <- adapter().get_range(key, loc.raw_offset, loc.raw_length) do
      verified(txid, bytes)
    end
  end

  defp verified(txid, bytes) do
    if txid(bytes) == txid, do: {:ok, bytes}, else: {:error, :bytes_do_not_hash_to_txid}
  end

  # Everything raw/1 needs to find a tx's bytes, in one query. `block_object`
  # is true only when the block's object is verified and the row is located.
  defp location(txid) do
    Repo.one(
      from t in Transaction,
        left_join: b in Bitblocks.Chain.Block,
        on: b.hash == t.block_hash,
        where: t.txid == ^txid,
        limit: 1,
        select: %{
          raw: t.raw,
          blob_stored_at: t.blob_stored_at,
          raw_offset: t.raw_offset,
          raw_length: t.raw_length,
          block_hash: t.block_hash,
          height: b.height,
          block_object:
            not is_nil(b.raw_object_stored_at) and not is_nil(t.raw_offset) and
              not is_nil(t.raw_length)
        }
    )
  end

  @doc """
  Where to download a tx's exact bytes: `TX_CDN_BASE_URL/tx/<txid>` once
  that's set, because CloudFront serves the path; until then the origin,
  `/api/v1/txs/<txid>/raw`, which answers for every tx we hold or can reach.
  """
  @spec download_url(String.t()) :: String.t()
  def download_url(txid) do
    case System.get_env("TX_CDN_BASE_URL") do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/") <> "/tx/" <> txid

      _ ->
        "/api/v1/txs/" <> txid <> "/raw"
    end
  end

  @doc "The public (CDN) URL for a stored tx, or nil when there's no CDN or it isn't stored."
  def url(%{txid: txid, blob_stored_at: %DateTime{}}), do: adapter().public_url(key(txid))
  def url(_), do: nil

  @doc """
  Enqueues blob storage for the given txids we hold and haven't stored yet.
  Returns the count enqueued, or `{:error, reason}` (logged once, no jobs)
  when the store isn't configured, rather than queueing work that can only fail.
  """
  def enqueue(txids) do
    with :ok <- ready?() do
      do_enqueue(txids)
    else
      {:error, reason} = error ->
        Logger.warning("TxStore: not enqueuing #{length(txids)} txs: #{inspect(reason)}")
        error
    end
  end

  @doc "Whether the configured adapter can take writes."
  def ready?, do: adapter().ready?()

  @doc """
  Re-checks up to `n` stored txs: each object must exist with the byte size of
  the database's copy. Returns `%{stored, checked, ok, bad}`.
  """
  def verify_sample(n \\ 20) do
    stored = Repo.aggregate(from(t in Transaction, where: not is_nil(t.blob_stored_at)), :count)

    txids =
      Repo.all(
        from t in Transaction,
          where: not is_nil(t.blob_stored_at),
          order_by: fragment("random()"),
          limit: ^n,
          select: t.txid
      )

    bad =
      for txid <- txids,
          {:ok, bytes} = db_bytes(txid),
          adapter().size(key(txid)) != {:ok, byte_size(bytes)},
          do: txid

    %{stored: stored, checked: length(txids), ok: length(txids) - length(bad), bad: bad}
  end

  @doc """
  Counts and cross-checks the store against the chain for blocks
  `from..to`, so a shortfall is a number rather than a silence:

    * `blocks`, `completed`: block rows in the range, and how many are done;
    * `block_objects`: completed blocks whose bytes are in the store as one
      verified object (`raw_object_stored_at`; `Bitblocks.TxStore.BlockObject`);
    * `block_objects_missing`: completed blocks without one, of which
      `block_objects_too_large` are over the raw-block cap and on the per-tx
      path: counted, never hidden;
    * `declared`: txs the headers declare (sum of `num_tx`);
    * `stored`: tx rows we hold for those heights;
    * `in_store`: those rows in the store, as their own object
      (`blob_stored_at`) or located in a stamped block object (`raw_offset`
      set); `in_block_objects` counts the second kind;
    * `sampled`, `sample_bad`: up to `sample` rows of each kind re-checked in
      the store: an own object by byte size, a block object by a ranged read
      whose bytes must hash to the txid (`range_sampled` of them);
    * `gaps`: each shortfall as `{kind, count}`, empty when everything adds up.

  Read-only. Counts run on the `height`, `block_height` and `blob_stored_at`
  indexes; give large spans in pieces (say 10,000 blocks) on a busy database.
  """
  @spec reconcile(non_neg_integer(), non_neg_integer(), keyword()) :: map()
  def reconcile(from, to, opts \\ []) when is_integer(from) and is_integer(to) and from <= to do
    sample = Keyword.get(opts, :sample, 20)
    max_bytes = Application.get_env(:bitblocks, :raw_block_max_bytes, 32 * 1024 * 1024)

    {blocks, completed, declared, block_objects, too_large} =
      Repo.one(
        from b in Bitblocks.Chain.Block,
          where: b.height >= ^from and b.height <= ^to,
          select: {
            count(),
            fragment("count(*) FILTER (WHERE ? = 'completed')", b.sync_state),
            coalesce(sum(b.num_tx), 0),
            fragment(
              "count(*) FILTER (WHERE ? = 'completed' AND ? IS NOT NULL)",
              b.sync_state,
              b.raw_object_stored_at
            ),
            fragment(
              "count(*) FILTER (WHERE ? = 'completed' AND ? IS NULL AND ? > ?)",
              b.sync_state,
              b.raw_object_stored_at,
              b.size,
              ^max_bytes
            )
          }
      )

    in_range = from(t in Transaction, where: t.block_height >= ^from and t.block_height <= ^to)

    located =
      from t in in_range,
        join: b in Bitblocks.Chain.Block,
        on: b.hash == t.block_hash,
        where: not is_nil(b.raw_object_stored_at) and not is_nil(t.raw_offset)

    stored = Repo.aggregate(in_range, :count)
    in_own_objects = Repo.aggregate(where(in_range, [t], not is_nil(t.blob_stored_at)), :count)
    in_block_objects = Repo.aggregate(located, :count)
    # A row in both kinds counts once.
    in_both = Repo.aggregate(where(located, [t], not is_nil(t.blob_stored_at)), :count)
    in_store = in_own_objects + in_block_objects - in_both

    txids =
      Repo.all(
        from t in in_range,
          where: not is_nil(t.blob_stored_at),
          order_by: fragment("random()"),
          limit: ^sample,
          select: t.txid
      )

    ranges =
      Repo.all(
        from [t, b] in located,
          order_by: fragment("random()"),
          limit: ^sample,
          select: {t.txid, b.height, b.hash, t.raw_offset, t.raw_length}
      )

    # Any failure to compare (no database copy, no object, a size that
    # differs, bytes that don't hash to the txid) counts as a mismatch, never
    # as a skip.
    bad =
      Enum.reject(txids, &matches_store?/1) ++
        for {txid, _, _, _, _} = range <- ranges, not range_matches?(range), do: txid

    declared = to_int(declared)
    block_objects_missing = completed - block_objects

    gaps =
      [
        {:blocks_missing, to - from + 1 - blocks},
        {:blocks_incomplete, blocks - completed},
        {:block_objects_missing, block_objects_missing},
        {:txs_not_stored, declared - stored},
        {:txs_not_in_store, stored - in_store},
        {:sample_mismatch, length(bad)}
      ]
      |> Enum.filter(fn {_kind, n} -> n != 0 end)

    %{
      from: from,
      to: to,
      blocks: blocks,
      completed: completed,
      block_objects: block_objects,
      block_objects_missing: block_objects_missing,
      block_objects_too_large: too_large,
      declared: declared,
      stored: stored,
      in_store: in_store,
      in_block_objects: in_block_objects,
      sampled: length(txids) + length(ranges),
      range_sampled: length(ranges),
      sample_bad: bad,
      gaps: gaps
    }
  end

  defp matches_store?(txid) do
    with {:ok, bytes} <- db_bytes(txid),
         {:ok, size} <- adapter().size(key(txid)) do
      size == byte_size(bytes)
    else
      _ -> false
    end
  end

  defp range_matches?({txid, height, hash, offset, length}) do
    key = Bitblocks.TxStore.BlockObject.key(height, hash)

    case adapter().get_range(key, offset, length) do
      {:ok, bytes} -> txid(bytes) == txid
      _ -> false
    end
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n

  defp do_enqueue(txids) do
    pending =
      Repo.all(
        from t in Transaction,
          where: t.txid in ^txids and is_nil(t.blob_stored_at) and not is_nil(t.raw),
          select: t.txid
      )

    Enum.each(pending, &Oban.insert!(Bitblocks.Workers.StoreTxBlobWorker.new(%{txid: &1})))
    length(pending)
  end

  defp db_bytes(txid) do
    case Repo.one(from t in Transaction, where: t.txid == ^txid, select: t.raw) do
      raw when is_binary(raw) and raw != "" -> decode_hex(raw)
      _ -> {:error, :not_found}
    end
  end

  defp decode_hex(raw) do
    case Base.decode16(raw, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_hex}
    end
  end

  @doc false
  def txid(bytes) do
    :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> :binary.list_to_bin()
    |> Base.encode16(case: :lower)
  end

  defp adapter,
    do: Application.get_env(:bitblocks, __MODULE__, []) |> Keyword.get(:adapter, __MODULE__.S3)
end
