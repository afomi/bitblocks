defmodule BitblocksWeb.ElectionArchive do
  @moduledoc """
  "Build the archive" on `/elections/:outpoint`, admins only
  (https://github.com/afomi/bitblocks/issues/136, step 5), and the zip behind
  "Download the archive (.zip)".

  Whether it can be built is `Archive.plan/2`'s answer, never a second rule.
  A build is `Archive.build/3` into a fresh temporary directory, under
  `:election_archive_timeout_ms` (20 s), and the directory is removed after.
  An election is small, so a build takes well under a second and needs no job.
  """

  require Logger

  alias Bitblocks.Elections
  alias Bitblocks.Elections.Archive
  alias BitblocksWeb.ElectionCount

  @default_timeout_ms 20_000

  @doc """
  `:ready`, or `{:refused, sentence}` saying why it can't be built yet.
  """
  @spec readiness(String.t()) :: :ready | {:refused, String.t()}
  def readiness(outpoint) do
    case bounded(fn -> Archive.plan(outpoint) end) do
      {:ok, _plan} -> :ready
      {:error, reason} -> {:refused, message(reason)}
    end
  end

  @doc """
  Builds the archive, reads it back, and returns what the page lists:
  `%{archive_sha256, files: [%{path, size, sha256}], beside: [...]}`, or
  `{:error, sentence}`.
  """
  @spec build(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(outpoint, opts \\ []) do
    in_temp_dir(fn dir ->
      with {:ok, built} <- Archive.build(outpoint, dir, opts) do
        {:ok,
         %{
           archive_sha256: built.archive_sha256,
           result_txid: built.result_txid,
           files: Enum.map(built.files, &listing/1),
           beside: Enum.map(built.beside, &listing/1)
         }}
      end
    end)
  end

  @doc """
  Builds the archive again and zips it: `{:ok, %{name, bytes,
  archive_sha256}}`, or `{:error, sentence}`.
  """
  @spec zip(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def zip(outpoint, opts \\ []) do
    in_temp_dir(fn dir ->
      with {:ok, built} <- Archive.build(outpoint, dir, opts),
           {:ok, zip} <- Archive.zip(built) do
        {:ok, Map.put(zip, :archive_sha256, built.archive_sha256)}
      end
    end)
  end

  @doc "What the page says once the archive can be built."
  @spec ready_message(non_neg_integer()) :: String.t()
  def ready_message(closes_at_height) do
    "Voting closed at block #{closes_at_height}, now #{Elections.depth()} or more blocks deep, so the archive can be built."
  end

  @doc "A refusal or failure in a sentence."
  @spec message(term()) :: String.t()
  def message({:too_shallow, %{closes_at_height: closes, blocks_remaining: left}}) do
    "Builds once block #{closes} is #{Elections.depth()} deep: #{blocks(left)} to go."
  end

  def message({:not_covered, %{needed_height: needed, covered_through: through}}) do
    "Builds once our index covers every block through #{needed}; it covers through #{through || "none yet"}."
  end

  def message(:roll_unconfirmed), do: "Builds once the roll is in a block."

  def message({:header_unavailable, height}),
    do: "Our headers don't hold a checked header at block #{height}, so it can't be built."

  def message({:header_chain_broken, height}),
    do: "Our headers don't chain at block #{height}, so it can't be built."

  def message(:invalid_result_txid),
    do: "A result record's txid is 64 lowercase hex characters."

  def message({:dir_not_empty, _dir, _files}), do: "The build folder wasn't empty."
  def message({:write_mismatch, path}), do: "#{path} didn't read back as written."
  def message({:write_failed, path, reason}), do: "#{path} couldn't be written (#{reason})."
  def message({:zip_failed, _reason}), do: "The zip couldn't be made."

  def message(:timeout),
    do: "The build took longer than #{div(timeout_ms(), 1000)} seconds, so it was stopped."

  def message({:crashed, _reason}), do: "The build failed. The error is in the server log."

  def message(reason), do: ElectionCount.message(reason)

  defp blocks(1), do: "1 block"
  defp blocks(n), do: "#{n} blocks"

  defp listing(%{path: path, bytes: bytes, sha256: sha256}),
    do: %{path: path, size: byte_size(bytes), sha256: sha256}

  defp in_temp_dir(fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "bitblocks-election-archive-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    try do
      case bounded(fn -> fun.(dir) end) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, message(reason)}
      end
    after
      File.rm_rf(dir)
    end
  end

  # Runs `fun` in a task, stopped after the timeout. Task.async carries
  # $callers, so the test sandbox follows.
  defp bounded(fun) do
    task = Task.async(fn -> safely(fun) end)

    case Task.yield(task, timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:crashed, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    exception ->
      Logger.error("election archive: " <> Exception.format(:error, exception, __STACKTRACE__))
      {:error, {:crashed, exception}}
  end

  defp timeout_ms,
    do: Application.get_env(:bitblocks, :election_archive_timeout_ms, @default_timeout_ms)
end
