defmodule Bitblocks.Repo.Migrations.AddBcatToCFiles do
  use Ecto.Migration

  # BCat files in the C:// index (https://github.com/afomi/bitblocks/issues/155):
  # a file split across several txs, addressed by the sha256 of the whole
  # file once it has been assembled from its chunks and verified.
  #
  # c_files gains:
  #
  # kind    — "b" for a single-output B:// file, "bcat" for a BCat file. A
  #           BCat row's txid and vout are its head's, and its size is the
  #           assembled file's. Rows written before this are B:// ("b").
  # chunks  — how many chunk txs a BCat file was joined from; nil for B://.
  #
  # c_file_misses holds the BCat heads we couldn't assemble, so a head we
  # can't index stays unindexed with its reason, never a guess:
  #
  # txid            — the head tx.
  # block_height    — the block the head was mined in; nil when unknown.
  # kind            — "bcat" (the only kind that can miss today).
  # reason          — missing_chunks | unavailable | too_large | no_chunks |
  #                   not_bcat | head_not_found.
  # missing_chunks  — the chunk txids no source had, for missing_chunks.
  # version         — the index_c_files step's version that tried.
  #
  # Both tables are small (B:// and BCat txs are rare). Nothing here touches
  # `transactions`.
  def change do
    alter table(:c_files) do
      add(:kind, :text, null: false, default: "b")
      add(:chunks, :integer)
    end

    create table(:c_file_misses) do
      add(:txid, :string, null: false)
      add(:block_height, :integer)
      add(:kind, :text, null: false, default: "bcat")
      add(:reason, :text, null: false)
      add(:missing_chunks, {:array, :string}, null: false, default: [])
      add(:version, :integer, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:c_file_misses, [:txid]))
  end
end
