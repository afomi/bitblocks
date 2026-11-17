defmodule Bitblocks.Migrations.DropUnusedTransactionsIndexesTest do
  # #92: six unused indexes on `transactions` are gone after migrating, and the
  # two the storage plan keeps are still there.
  use Bitblocks.DataCase, async: true

  alias Bitblocks.Repo

  @dropped ~w(
    transactions_total_output_satoshis_index
    transactions_total_input_satoshis_index
    transactions_inserted_at_index
    transactions_script_analysis_version_index
    transactions_output_count_index
    transactions_input_count_index
  )

  @kept ~w(transactions_output_script_hashes_index transactions_aip_signers_index)

  test "the six unused transactions indexes are dropped and the kept two remain" do
    %{rows: rows} =
      Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = 'transactions'")

    names = List.flatten(rows)

    for name <- @dropped, do: refute(name in names, "#{name} should be dropped")
    for name <- @kept, do: assert(name in names, "#{name} should be kept")
  end
end
