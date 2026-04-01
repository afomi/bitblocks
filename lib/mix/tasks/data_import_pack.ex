defmodule Mix.Tasks.Data.Import.Pack do
  @moduledoc """
  Import a local data pack into the Bitblocks database.

  Example:

      mix data.import.pack --path tmp/data_packs/mainnet-000000-000999-full
  """

  use Mix.Task

  alias Bitblocks.DataPacks.Importer

  @shortdoc "Import a local data pack into the database"

  @switches [
    path: :string,
    chunk_size: :integer
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    pack_dir =
      case Keyword.get(opts, :path) do
        nil -> Mix.raise("missing required option --path")
        path -> path
      end

    {:ok, result} =
      Importer.import_pack(pack_dir, chunk_size: Keyword.get(opts, :chunk_size, 500))

    Mix.shell().info("Imported pack from #{pack_dir}")
    Mix.shell().info("Blocks imported: #{result.blocks_imported}")
    Mix.shell().info("Transactions imported: #{result.transactions_imported}")
  end
end
