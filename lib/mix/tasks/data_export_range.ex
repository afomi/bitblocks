defmodule Mix.Tasks.Data.Export.Range do
  @moduledoc """
  Export a bounded range of blocks into a portable data pack.

  This task is intentionally RPC-first so it can be run directly on a node host
  over SSH without requiring a local Bitblocks database.

  Example:

      mix data.export.range --start-height 0 --end-height 999 --fidelity full --output-root tmp/data_packs
  """

  use Mix.Task

  alias Bitblocks.DataPacks.{Exporter, Spec}

  @shortdoc "Export a block range into a local data pack"

  @switches [
    start_height: :integer,
    end_height: :integer,
    fidelity: :string,
    output_root: :string,
    name: :string,
    network: :string,
    block_chunk_size: :integer,
    tx_chunk_size: :integer
  ]

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:httpoison)

    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    with {:ok, spec} <- Spec.build(opts),
         {:ok, result} <- Exporter.export_range(spec) do
      Mix.shell().info("Exported #{result.manifest["name"] || result.manifest[:name]} to #{result.output_dir}")
      Mix.shell().info("Blocks: #{result.manifest[:block_count] || result.manifest["block_count"]}")
      Mix.shell().info("Transactions: #{result.manifest[:transaction_count] || result.manifest["transaction_count"]}")
    else
      {:error, message} ->
        Mix.raise(message)
    end
  end
end
