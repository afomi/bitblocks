defmodule Bitblocks.TxStore.S3 do
  @moduledoc """
  S3 adapter for `Bitblocks.TxStore`. Bucket `AWS_S3_BUCKET_TXS`; public URL
  base `CDN_BASE_URL` (CloudFront). Credentials come from the instance role.
  Objects are `application/octet-stream`, `Cache-Control: public, immutable,
  max-age=31536000`.
  """

  @behaviour Bitblocks.TxStore

  @cache_control "public, immutable, max-age=31536000"

  # Multipart requests retry at most 3 times with short backoff (ExAws's
  # default is 10 attempts), so a slow or throttled part fails well within
  # the block object's write timeout rather than stalling for minutes.
  @multipart_retries [
    retries: [max_attempts: 3, base_backoff_in_ms: 200, max_backoff_in_ms: 5_000]
  ]

  @impl true
  def put(key, bytes) do
    with {:ok, bucket} <- bucket() do
      bucket
      |> ExAws.S3.put_object(key, bytes,
        content_type: "application/octet-stream",
        cache_control: @cache_control
      )
      |> ExAws.request()
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:s3_put, reason}}
      end
    end
  end

  @impl true
  def get(key) do
    with {:ok, bucket} <- bucket() do
      case bucket |> ExAws.S3.get_object(key) |> ExAws.request() do
        {:ok, %{body: body}} -> {:ok, body}
        {:error, {:http_error, 404, _}} -> {:error, :not_found}
        {:error, reason} -> {:error, {:s3_get, reason}}
      end
    end
  end

  # An HTTP Range GET: `bytes=<first>-<last>`, inclusive. A 206 with exactly
  # `length` bytes is the only success.
  @impl true
  def get_range(key, offset, length) do
    with {:ok, bucket} <- bucket() do
      range = "bytes=#{offset}-#{offset + length - 1}"

      case bucket |> ExAws.S3.get_object(key, range: range) |> ExAws.request() do
        {:ok, %{body: body}} when byte_size(body) == length -> {:ok, body}
        {:ok, %{body: body}} -> {:error, {:short_read, byte_size(body), length}}
        {:error, {:http_error, 404, _}} -> {:error, :not_found}
        {:error, {:http_error, 416, _}} -> {:error, :range_not_satisfiable}
        {:error, reason} -> {:error, {:s3_get, reason}}
      end
    end
  end

  @impl true
  def size(key) do
    with {:ok, bucket} <- bucket() do
      case bucket |> ExAws.S3.head_object(key) |> ExAws.request() do
        {:ok, %{headers: headers}} ->
          headers
          |> Enum.find_value(fn {k, v} -> if String.downcase(k) == "content-length", do: v end)
          |> case do
            nil -> {:error, :no_content_length}
            length -> {:ok, String.to_integer(length)}
          end

        {:error, {:http_error, 404, _}} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, {:s3_head, reason}}
      end
    end
  end

  @impl true
  def multipart_start(key) do
    with {:ok, bucket} <- bucket() do
      bucket
      |> ExAws.S3.initiate_multipart_upload(key,
        content_type: "application/octet-stream",
        cache_control: @cache_control
      )
      |> ExAws.request(@multipart_retries)
      |> case do
        {:ok, %{body: %{upload_id: id}}} when is_binary(id) and id != "" ->
          {:ok, %{bucket: bucket, key: key, upload_id: id}}

        {:ok, other} ->
          {:error, {:s3_multipart_start, {:no_upload_id, other}}}

        {:error, reason} ->
          {:error, {:s3_multipart_start, reason}}
      end
    end
  end

  # The part's ETag is what `complete` names it by.
  @impl true
  def multipart_put_part(%{bucket: bucket, key: key, upload_id: id}, number, bytes) do
    case bucket
         |> ExAws.S3.upload_part(key, id, number, bytes)
         |> ExAws.request(@multipart_retries) do
      {:ok, %{headers: headers}} ->
        case Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == "etag", do: v end) do
          nil -> {:error, {:s3_upload_part, number, :no_etag}}
          etag -> {:ok, {number, etag}}
        end

      {:error, reason} ->
        {:error, {:s3_upload_part, number, reason}}
    end
  end

  @impl true
  def multipart_complete(%{bucket: bucket, key: key, upload_id: id}, parts) do
    case bucket
         |> ExAws.S3.complete_multipart_upload(key, id, parts)
         |> ExAws.request(@multipart_retries) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:s3_multipart_complete, reason}}
    end
  end

  @impl true
  def multipart_abort(%{bucket: bucket, key: key, upload_id: id}) do
    case bucket
         |> ExAws.S3.abort_multipart_upload(key, id)
         |> ExAws.request(@multipart_retries) do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> :ok
      {:error, reason} -> {:error, {:s3_multipart_abort, reason}}
    end
  end

  # Signed locally with the instance role's credentials (its session token
  # rides in the URL); no request to S3. The bucket stays private: only a
  # URL signed here, before it expires, can read the object.
  @impl true
  def presigned_url(key, ttl_seconds, filename) do
    with {:ok, bucket} <- bucket() do
      ExAws.Config.new(:s3)
      |> ExAws.S3.presigned_url(:get, bucket, key,
        expires_in: ttl_seconds,
        query_params: [
          {"response-content-disposition", ~s(attachment; filename="#{filename}")}
        ]
      )
      |> case do
        {:ok, url} -> {:ok, url}
        {:error, reason} -> {:error, {:s3_presign, reason}}
      end
    end
  end

  @impl true
  def ready?, do: with({:ok, _} <- bucket(), do: :ok)

  @impl true
  def public_url(key) do
    case System.get_env("CDN_BASE_URL") do
      base when is_binary(base) and base != "" -> String.trim_trailing(base, "/") <> "/" <> key
      _ -> nil
    end
  end

  defp bucket do
    case System.get_env("AWS_S3_BUCKET_TXS") do
      bucket when is_binary(bucket) and bucket != "" -> {:ok, bucket}
      _ -> {:error, :no_bucket_configured}
    end
  end
end
