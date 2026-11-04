defmodule Bitblocks.Chain.TxPipelineDocTest do
  # docs/TX_PIPELINE.md depicts TxPipeline.steps/0. The numbered table rows
  # must name exactly those steps, in order, so the two can't drift.
  use ExUnit.Case, async: true

  alias Bitblocks.Chain.TxPipeline

  @doc_path "docs/TX_PIPELINE.md"

  test "the doc's step tables list exactly TxPipeline.steps/0, in order" do
    documented =
      Regex.scan(~r/^\| (\d+) \| `([a-z_]+)` \|/m, File.read!(@doc_path))
      |> Enum.map(fn [_, n, name] -> {String.to_integer(n), name} end)

    assert documented ==
             TxPipeline.steps()
             |> Enum.with_index(1)
             |> Enum.map(fn {step, n} -> {n, step.name()} end)
  end

  test "each step sits in its stage's table" do
    doc = File.read!(@doc_path)

    for {stage, heading} <- [
          chunk: "### Chunk steps",
          tx: "### Tx steps",
          block: "### Block steps"
        ] do
      [_, section] = String.split(doc, heading, parts: 2)
      [section | _] = String.split(section, "\n### ", parts: 2)

      for step <- TxPipeline.steps(stage) do
        assert section =~ "`#{step.name()}`", "#{step.name()} is missing from #{heading}"
      end
    end
  end
end
