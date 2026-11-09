defmodule Bitblocks.Repo.Migrations.AddTxTypesVersionToBlocks do
  use Ecto.Migration

  # The tx types coverage of a whole block: TxPipeline.version(:tx_types) when
  # every tx of the block is typed at that version, whether its own row says
  # so (transactions.tx_types_version) or not. Release.backfill_tx_types/3
  # writes only the rows whose types change and stamps the block for the
  # rest, so a classifier bump doesn't rewrite every row of `transactions`.
  # Nil until a block is typed this way. docs/DERIVED_DATA.md.
  def change do
    alter table(:blocks) do
      add(:tx_types_version, :integer)
    end
  end
end
