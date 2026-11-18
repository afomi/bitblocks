defmodule Bitblocks.TxStore.Local do
  @moduledoc """
  Filesystem adapter for `Bitblocks.TxStore` (dev and test). Objects live
  under `config :bitblocks, Bitblocks.TxStore, root: …` (default `tmp/tx_store`).
  No public URL.
  """

  @behaviour Bitblocks.TxStore

  @impl true
  def put(key, bytes) do
    path = path(key)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".part", bytes),
         :ok <- File.rename(path <> ".part", path) do
      :ok
    end
  end

  @impl true
  def get(key) do
    case File.read(path(key)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, :not_found}
      error -> error
    end
  end

  @impl true
  def get_range(key, offset, length) do
    case File.open(path(key), [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          case :file.pread(file, offset, length) do
            {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
            {:ok, bytes} -> {:error, {:short_read, byte_size(bytes), length}}
            :eof -> {:error, {:short_read, 0, length}}
            {:error, reason} -> {:error, reason}
          end
        after
          File.close(file)
        end

      {:error, :enoent} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  @impl true
  def size(key) do
    case File.stat(path(key)) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, :enoent} -> {:error, :not_found}
      error -> error
    end
  end

  # Parts go to a directory beside the object, one file each, joined in
  # part order by `complete` and renamed into place; `abort` removes the
  # directory. S3's 5 MiB minimum for every part but the last is enforced
  # here too (as S3 does, at `complete`), so a caller that would fail on S3
  # fails in dev and test.
  @impl true
  def multipart_start(key) do
    dir = path(key) <> ".multipart-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    case File.mkdir_p(dir) do
      :ok -> {:ok, %{key: key, dir: dir}}
      error -> error
    end
  end

  @impl true
  def multipart_put_part(%{dir: dir}, number, bytes) when is_integer(number) and number >= 1 do
    case File.write(Path.join(dir, part_name(number)), bytes) do
      :ok -> {:ok, {number, byte_size(bytes)}}
      error -> error
    end
  end

  @impl true
  def multipart_complete(%{key: key, dir: dir}, parts) do
    numbers = Enum.map(parts, &elem(&1, 0))
    sizes = Enum.map(parts, &elem(&1, 1))
    target = path(key)

    cond do
      parts == [] or numbers != Enum.to_list(1..length(parts)) ->
        {:error, :invalid_part_order}

      Enum.any?(Enum.drop(sizes, -1), &(&1 < Bitblocks.TxStore.min_part_bytes())) ->
        {:error, :entity_too_small}

      true ->
        with :ok <- File.mkdir_p(Path.dirname(target)),
             :ok <- join_parts(dir, numbers, target <> ".part"),
             :ok <- File.rename(target <> ".part", target) do
          File.rm_rf(dir)
          :ok
        end
    end
  end

  @impl true
  def multipart_abort(%{dir: dir}) do
    case File.rm_rf(dir) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end

  defp join_parts(dir, numbers, out) do
    File.open(out, [:write, :binary, :raw], fn file ->
      Enum.reduce_while(numbers, :ok, fn n, :ok ->
        with {:ok, bytes} <- File.read(Path.join(dir, part_name(n))),
             :ok <- :file.write(file, bytes) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:ok, error} -> error
      error -> error
    end
  end

  defp part_name(number), do: String.pad_leading(Integer.to_string(number), 5, "0")

  @impl true
  def public_url(_key), do: nil

  @impl true
  def ready?, do: :ok

  defp path(key) do
    root =
      Application.get_env(:bitblocks, Bitblocks.TxStore, [])
      |> Keyword.get(:root, "tmp/tx_store")

    Path.join(root, key)
  end
end
