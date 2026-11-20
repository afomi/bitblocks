defmodule Bitblocks.Repo.Migrations.CreateCFiles do
  use Ecto.Migration

  # The C:// index (https://github.com/afomi/bitblocks/issues/147): one row
  # per B:// file output, keyed by the sha256 of its bytes, so `/c/:sha256`
  # finds the outputs that carry a file without scanning `transactions`.
  #
  # B:// files are rare, so this table stays small, and filling it never
  # touches `transactions` (no index is added there).
  #
  # sha256        — the sha256 of the file's bytes: its C:// address. Raw
  #                 32 bytes; the API shows it as lowercase hex. The same
  #                 bytes in several txs share it, so it isn't unique.
  # txid, vout    — the output that carries the file.
  # block_height  — the block the tx was mined in; nil when unknown.
  # media_type    — as the B:// output states it; nil when blank.
  # encoding      — as stated; nil when blank.
  # filename      — as stated; nil when blank.
  # size          — the file's length in bytes.
  # version       — the index_c_files step's version that wrote the row.
  def change do
    create table(:c_files) do
      add(:sha256, :binary, null: false)
      add(:txid, :string, null: false)
      add(:vout, :integer, null: false)
      add(:block_height, :integer)
      add(:media_type, :text)
      add(:encoding, :text)
      add(:filename, :text)
      add(:size, :bigint, null: false)
      add(:version, :integer, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:c_files, [:txid, :vout]))
    create(index(:c_files, [:sha256]))
  end
end
