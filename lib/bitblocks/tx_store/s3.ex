defmodule Bitblocks.TxStore.S3 do
  @moduledoc """
  S3 adapter for `Bitblocks.TxStore`. Bucket `AWS_S3_BUCKET_TXS`; public URL
  base `CDN_BASE_URL` (CloudFront). Credentials come from the instance role.
  Objects are `application/octet-stream`, `Cache-Control: public, immutable,
  max-age=31536000`.
  """

  @behaviour Bitblocks.TxStore

  @cache_control "public, immutable, max-age=31536000"

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
