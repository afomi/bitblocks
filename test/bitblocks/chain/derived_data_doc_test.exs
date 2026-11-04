defmodule Bitblocks.Chain.DerivedDataDocTest do
  # docs/DERIVED_DATA.md is authoritative for derived data. Its tables must
  # list every step of TxPipeline.steps/0, in order, at its current stage and
  # version, and every derivation at its current version, so a version bump
  # can't ship without the doc saying so.
  use ExUnit.Case, async: true

  alias Bitblocks.Chain.TxPipeline

  @doc_path "docs/DERIVED_DATA.md"

  test "the step table lists every step with its stage and current version, in order" do
    documented =
      Regex.scan(~r/^\| `([a-z_]+)` \| (chunk|tx|block) \| (\d+) \|/m, File.read!(@doc_path))
      |> Enum.map(fn [_, name, stage, version] -> {name, stage, String.to_integer(version)} end)

    assert documented ==
             Enum.map(TxPipeline.steps(), &{&1.name(), to_string(&1.stage()), &1.version()})
  end

  test "the derivation table lists every derivation with its current version and stamp" do
    documented =
      Regex.scan(
        ~r/^\| `([a-z_]+)` \| [^|]+ \| (\d+) \| `([a-z_]+\.[a-z_]+)` \|/m,
        File.read!(@doc_path)
      )
      |> Enum.map(fn [_, name, version, stamp] -> {name, String.to_integer(version), stamp} end)

    assert documented ==
             for(
               {name, d} <- TxPipeline.derivations(),
               do: {to_string(name), TxPipeline.version(name), d.stamp}
             )
  end

  test "the stage versions are current" do
    assert File.read!(@doc_path) =~
             "Stage versions today: chunk #{TxPipeline.version(:chunk)}, " <>
               "tx #{TxPipeline.version(:tx)}, block #{TxPipeline.version(:block)}."
  end
end
