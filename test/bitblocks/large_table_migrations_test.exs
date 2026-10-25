defmodule Bitblocks.LargeTableMigrationsTest do
  # Guards #28: a plain CREATE INDEX on a large table blocks writes (tip sync
  # stalls) for the whole build. Migrations after the cutoff must build such
  # indexes concurrently, outside the migration transaction. See AGENTS.md.
  use ExUnit.Case, async: true

  @large_tables ~w(transactions)
  # Migrations up to here were written before the rule (and already ran in prod).
  @cutoff "20261020000001"

  @migrations Path.wildcard("priv/repo/migrations/*.exs")

  test "migrations exist to check" do
    assert Path.wildcard("priv/repo/migrations/*.exs") != []
  end

  for path <- @migrations,
      version = path |> Path.basename() |> String.split("_") |> hd(),
      version > @cutoff do
    @path path
    test "#{Path.basename(path)} indexes large tables concurrently" do
      source = File.read!(@path)

      for table <- @large_tables, indexes?(source, table) do
        assert source =~ "concurrently: true" or source =~ ~r/CREATE INDEX CONCURRENTLY/i,
               "#{@path} indexes :#{table} without concurrently: true"

        assert source =~ "@disable_ddl_transaction true",
               "#{@path} needs @disable_ddl_transaction true for a concurrent index on :#{table}"
      end
    end
  end

  defp indexes?(source, table) do
    source =~ ~r/index\(\s*:#{table}\b/ or source =~ ~r/CREATE (UNIQUE )?INDEX.*\bON #{table}\b/is
  end

  test "the check catches a plain index on transactions" do
    for table <- @large_tables do
      assert indexes?(~s|create(index(:#{table}, [:x], using: "GIN"))|, table)
      assert indexes?("CREATE INDEX foo ON #{table} (x)", table)
    end

    refute indexes?(~s|create(index(:transaction_inputs, [:x]))|, "transactions")
  end
end
