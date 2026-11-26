defmodule Bitblocks.ArrayIndexQueriesTest do
  # The tag columns on `transactions` are GIN-indexed, but GIN serves only
  # containment (`col @> ARRAY[x]`), not membership (`x = ANY(col)`, which is
  # what Ecto's `^x in t.col` compiles to). Membership seq-scans the whole
  # table, tens of GB in prod. Write `fragment("? @> ARRAY[?]::varchar[]", ...)`.
  use Bitblocks.DataCase, async: true

  alias Bitblocks.Chain.Transaction

  @gin_columns ~w(output_addresses protocols output_script_hashes output_template_hashes aip_signers input_txids)

  # The one deliberate membership match: a projection's narrowing columns
  # (output_script_hashes, aip_signers), whose GIN indexes are ready to drop
  # (docs/INDEXES.md). The changeset never lets one stand alone, so an
  # indexed column bounds the rows first; projections_test.exs checks the plan.
  @narrowing_match {"lib/bitblocks/projections.ex",
                    ~s|fragment("? = ANY(?)", ^value, field(t, ^field))|}

  test "no query in lib/ uses membership on a GIN-indexed array column" do
    columns = Enum.join(@gin_columns, "|")
    membership = ~r/(\^\w+ in \w+\.(#{columns})\b|ANY\(\?\))/

    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ membership,
          not narrowing_match?(path, line),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  test "containment uses the GIN index and membership doesn't" do
    contains =
      from t in Transaction,
        where: fragment("? @> ARRAY[?]::varchar[]", t.output_addresses, ^"1abc")

    member = from t in Transaction, where: ^"1abc" in t.output_addresses

    assert plan(contains) =~ "transactions_output_addresses_index"
    assert plan(member) =~ "Seq Scan on transactions"
  end

  defp narrowing_match?(path, line) do
    {narrowing_path, fragment} = @narrowing_match
    path == narrowing_path and String.contains?(line, fragment)
  end

  # The test table is tiny, so turn seq scans off: a predicate the index can
  # serve then uses it, and one it can't still seq-scans.
  defp plan(query) do
    Repo.query!("SET LOCAL enable_seqscan = off")
    {sql, params} = Repo.to_sql(:all, query)
    Repo.query!("EXPLAIN " <> sql, params).rows |> Enum.map_join("\n", &hd/1)
  end
end
