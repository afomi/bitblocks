defmodule Bitblocks.WorkflowPathsIgnoreTest do
  # #93: CI and the deploy skip a push touching only docs, and still run for
  # any code change, so their paths-ignore lists hold docs patterns and nothing else.
  use ExUnit.Case, async: true

  @docs_only ["**.md", "docs/**", ".claude/**"]

  for {file, triggers} <- [{"ci.yml", 2}, {"aws-deploy.yml", 1}] do
    @workflow Path.join(".github/workflows", file)
    @triggers triggers

    test "#{file} ignores docs-only pushes and nothing else" do
      lists = paths_ignore_lists(File.read!(@workflow))

      assert length(lists) == @triggers,
             "#{@workflow} should have paths-ignore on #{@triggers} trigger(s), found #{length(lists)}"

      for list <- lists, do: assert(Enum.sort(list) == Enum.sort(@docs_only))
    end
  end

  test "the deploy can still be run by hand" do
    assert File.read!(".github/workflows/aws-deploy.yml") =~ ~r/^  workflow_dispatch:/m
  end

  # Each `paths-ignore:` block's quoted patterns, comments skipped.
  defp paths_ignore_lists(source) do
    source
    |> String.split(~r/^\s*paths-ignore:\s*$/m)
    |> tl()
    |> Enum.map(fn block ->
      block
      |> String.split("\n")
      |> Enum.reject(&(&1 == "" or String.starts_with?(String.trim_leading(&1), "#")))
      |> Enum.take_while(&String.match?(&1, ~r/^\s+- /))
      |> Enum.map(&hd(Regex.run(~r/-\s+"([^"]+)"/, &1, capture: :all_but_first)))
    end)
  end
end
