defmodule Bitblocks.Repo.Migrations.AddSourceToProjections do
  use Ecto.Migration

  # Tenant 3 of #29 (docs/MANAGED_SERVICES.md): a projection reads either
  # `transactions` (its filter over the tag columns) or `bitcom_commands` (the
  # Bitcom registry's command log, whole). Existing rows are `transactions`.
  #
  # The index serves a command projection's order, (block_height, txid,
  # output_index), for hydrate's keyset pages and follow's per-height reads.
  # `bitcom_commands` is a small table (one row per Bitcom `$` command ever
  # seen), so a plain build is quick; nothing is indexed on `transactions`.
  def change do
    alter table(:projections) do
      add(:source, :string, null: false, default: "transactions")
    end

    create(index(:bitcom_commands, [:block_height, :txid, :output_index]))
  end
end
