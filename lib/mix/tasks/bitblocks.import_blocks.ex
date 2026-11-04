defmodule Mix.Tasks.Bitblocks.ImportBlocks do
  @moduledoc """
  Imports raw blocks exported from our node (`<height>-<hash>.bin`, written
  by `scripts/export_blocks` on the node host) into the local database, with
  no node calls. See `Bitblocks.Chain.BlockImport`.

      mix bitblocks.import_blocks ~/blocks/900000-900099

  Prints each block's outcome and a summary, and exits non-zero if any
  block failed its checks.
  """
  use Mix.Task

  alias Bitblocks.Chain.BlockImport

  @shortdoc "Import exported raw block files"

  @impl true
  def run([dir]) do
    # Import only: don't start the sync loop against a node during the run.
    Application.put_env(:bitblocks, Bitblocks.Sync.Coordinator, auto: false, headers: false)
    Mix.Task.run("app.start")

    files = BlockImport.block_files(Path.expand(dir))
    Mix.shell().info("#{length(files)} block file(s) in #{dir}")
    started = System.monotonic_time(:millisecond)

    {:ok, report} = BlockImport.import_dir(dir)
    seconds = max((System.monotonic_time(:millisecond) - started) / 1000, 0.001)
    mb = files |> Enum.map(&File.stat!(&1.path).size) |> Enum.sum() |> Kernel./(1_000_000)

    for {height, reason} <- report.failed,
        do: Mix.shell().error("  #{height}: failed: #{inspect(reason)}")

    Mix.shell().info("""
    completed:        #{length(report.completed)}
    already complete: #{length(report.already_complete)}
    failed:           #{length(report.failed)}
    #{Float.round(mb, 1)} MB in #{Float.round(seconds, 1)} s (#{Float.round(mb / seconds, 2)} MB/s, #{Float.round(length(files) / seconds * 60, 1)} blocks/min)
    """)

    if report.failed != [], do: exit({:shutdown, 1})
  end

  def run(_), do: Mix.raise("usage: mix bitblocks.import_blocks <dir>")
end
