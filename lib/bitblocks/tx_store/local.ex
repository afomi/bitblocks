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
