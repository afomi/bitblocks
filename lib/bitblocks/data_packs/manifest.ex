defmodule Bitblocks.DataPacks.Manifest do
  @moduledoc false

  alias Bitblocks.DataPacks.Spec

  def build(%Spec{} = spec, stats) do
    %{
      schema_version: 1,
      name: spec.name,
      network: spec.network,
      selection: %{
        type: "range",
        start_height: spec.start_height,
        end_height: spec.end_height
      },
      fidelity: Atom.to_string(spec.fidelity),
      exported_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      block_count: stats.block_count,
      transaction_count: stats.transaction_count,
      files: files_for(spec, stats)
    }
  end

  defp files_for(%Spec{fidelity: :full}, stats) do
    [
      %{path: "blocks.jsonl", records: stats.block_count},
      %{path: "transactions.jsonl", records: stats.transaction_count}
    ]
  end

  defp files_for(_spec, stats) do
    [%{path: "blocks.jsonl", records: stats.block_count}]
  end
end
