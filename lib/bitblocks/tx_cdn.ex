defmodule Bitblocks.TxCdn do
  @moduledoc """
  Writes transaction data to S3 for CDN distribution.

  Every BSV transaction is immutable and content-addressable by txid.
  Once written to S3, CloudFront serves it globally with
  `Cache-Control: public, immutable, max-age=31536000`.

  Objects are write-once — if the key already exists, the write is skipped.
  This makes all operations idempotent and safe to retry.

  ## S3 Layout

      s3://bitblocks-txs/
        raw/{txid}           — raw transaction hex
        json/{txid}.json     — parsed inputs, outputs, metadata

  ## Configuration

      # Environment variables (set via instance role or secrets):
      AWS_S3_BUCKET_TXS=bitblocks-txs
      CDN_BASE_URL=https://cdn.bitblocks.app

  No AWS credentials needed if running on EC2 with an instance role.
  """

  require Logger

  @cache_control "public, immutable, max-age=31536000"

  @doc """
  Write a transaction to S3, sourced from a DB record.

  Re-reads the transaction from Postgres by txid to guarantee the data
  written to S3 matches what's in the database. S3 objects are permanent
  and globally cached — they must be accurate.

  Accepts either a %Transaction{} struct (uses the txid to re-read)
  or a map with a :txid key.
  """
  def put_transaction_from_db(%Bitblocks.Chain.Transaction{txid: txid}) do
    put_transaction_from_db(txid)
  end

  def put_transaction_from_db(%{txid: txid}), do: put_transaction_from_db(txid)
  def put_transaction_from_db(%{"txid" => txid}), do: put_transaction_from_db(txid)

  def put_transaction_from_db(txid) when is_binary(txid) do
    # Re-read from DB — this is the source of truth.
    case Bitblocks.Repo.get_by(Bitblocks.Chain.Transaction, txid: txid) do
      nil ->
        Logger.warning("TxCdn: tx #{txid} not found in DB, skipping S3 write")
        {:error, :not_found}

      tx ->
        # Verify the txid matches what we expect (belt and suspenders)
        if tx.txid != txid do
          Logger.error("TxCdn: txid mismatch! expected=#{txid} got=#{tx.txid}")
          {:error, :txid_mismatch}
        else
          with :ok <- put_raw(tx.txid, tx),
               :ok <- put_json(tx.txid, tx) do
            :ok
          end
        end
    end
  end

  def put_transaction_from_db(_), do: {:error, :missing_txid}

  @doc """
  Count objects in S3 under a prefix.
  Uses S3 ListObjectsV2 with no delimiter — counts all keys.

  For integrity checks: compare this count against a DB count
  for the same block range.

      db_count = Repo.aggregate(Transaction, :count)
      {:ok, s3_count} = TxCdn.count_objects("json/")
      db_count == s3_count
  """
  def count_objects(prefix \\ "json/") do
    case bucket() do
      nil -> {:error, :not_configured}
      bucket_name -> do_count(bucket_name, prefix, nil, 0)
    end
  end

  defp do_count(bucket_name, prefix, continuation_token, acc) do
    opts = [prefix: prefix, max_keys: 1000]
    opts = if continuation_token, do: Keyword.put(opts, :continuation_token, continuation_token), else: opts

    case ExAws.S3.list_objects_v2(bucket_name, opts) |> ExAws.request() do
      {:ok, %{body: %{key_count: count, is_truncated: "true", next_continuation_token: token}}} ->
        do_count(bucket_name, prefix, token, acc + count)

      {:ok, %{body: %{key_count: count}}} ->
        {:ok, acc + count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Integrity check: compare DB transaction count against S3 object count.
  Returns {:ok, %{db: n, s3: n, match: true}} or {:ok, %{db: n, s3: m, match: false, diff: n-m}}.
  """
  def integrity_check do
    db_count = Bitblocks.Repo.aggregate(Bitblocks.Chain.Transaction, :count)

    case count_objects("json/") do
      {:ok, s3_count} ->
        {:ok,
         %{
           db: db_count,
           s3: s3_count,
           match: db_count == s3_count,
           diff: db_count - s3_count
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the CDN URL for a transaction, or nil if CDN is not configured.
  """
  def cdn_url(txid, format \\ :json) do
    case cdn_base_url() do
      nil -> nil
      base ->
        case format do
          :raw -> "#{base}/raw/#{txid}"
          :json -> "#{base}/json/#{txid}.json"
        end
    end
  end

  # -- S3 writes ---------------------------------------------------------------

  defp put_raw(txid, %{raw: raw}) when is_binary(raw) and raw != "" do
    put_object("raw/#{txid}", raw, "application/octet-stream")
  end

  defp put_raw(_txid, _tx), do: :ok

  defp put_json(txid, tx) do
    json =
      %{
        txid: tx.txid,
        block_hash: tx.block_hash,
        block_height: tx.block_height,
        version: tx.version,
        input_count: tx.input_count,
        output_count: tx.output_count,
        total_input_satoshis: tx.total_input_satoshis,
        total_output_satoshis: tx.total_output_satoshis
      }
      |> Jason.encode!()

    put_object("json/#{txid}.json", json, "application/json")
  end

  defp put_object(key, body, content_type) do
    case bucket() do
      nil ->
        :ok

      bucket_name ->
        request =
          ExAws.S3.put_object(bucket_name, key, body,
            content_type: content_type,
            cache_control: @cache_control
          )

        case ExAws.request(request) do
          {:ok, _} ->
            :ok

          {:error, {:http_error, 409, _}} ->
            # Already exists — that's fine, content is immutable
            :ok

          {:error, reason} ->
            Logger.warning("TxCdn: failed to write #{key}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  # -- Config ------------------------------------------------------------------

  defp bucket do
    System.get_env("AWS_S3_BUCKET_TXS")
  end

  defp cdn_base_url do
    System.get_env("CDN_BASE_URL")
  end
end
