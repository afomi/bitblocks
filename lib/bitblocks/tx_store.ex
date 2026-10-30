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
      `raw` column while it still holds it, then the blob store, so large
      payloads can later leave Postgres without changing callers.

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

  @doc "Raw bytes for a txid: the database's copy if it has one, else the blob store's."
  @spec raw(String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  def raw(txid) do
    case db_bytes(txid) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, :not_found} ->
        with {:ok, bytes} <- adapter().get(key(txid)),
             ^txid <- txid(bytes) do
          {:ok, bytes}
        else
          {:error, _} = error -> error
          _ -> {:error, :bytes_do_not_hash_to_txid}
        end
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
      raw when is_binary(raw) and raw != "" ->
        case Base.decode16(raw, case: :mixed) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, :invalid_hex}
        end

      _ ->
        {:error, :not_found}
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
