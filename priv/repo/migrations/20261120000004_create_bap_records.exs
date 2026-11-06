defmodule Bitblocks.Repo.Migrations.CreateBapRecords do
  use Ecto.Migration

  # One BAP record with a valid AIP signature: what a transaction output says,
  # and who signed it (#32). What the records mean together (which are
  # accepted, who an identity is now) is worked out when read, from the rules
  # in docs/BAP.md, so a change of rule needs no re-index.
  #
  # Height, block and position in the block aren't kept here: they are read from
  # the `transactions` row, so a reorg that moves the row moves its records.
  #
  # txid, vout       — where the record is.
  # action           — ID, ALIAS, ATTEST or REVOKE.
  # bap_id           — the identity named (ID, ALIAS); nil otherwise.
  # address          — the signing address an ID record declares; nil otherwise.
  # signer           — the address whose AIP signature checked.
  # attestation_hash — what ATTEST and REVOKE refer to; nil otherwise.
  # seq              — ATTEST and REVOKE's sequence number, as written.
  # profile          — ALIAS's profile JSON; nil when it isn't a JSON object.
  # version          — the index_bap step's version that wrote the row.
  def change do
    create table(:bap_records) do
      add(:txid, :string, null: false)
      add(:vout, :integer, null: false)
      add(:action, :string, null: false)
      add(:bap_id, :string)
      add(:address, :string)
      add(:signer, :string, null: false)
      add(:attestation_hash, :string)
      add(:seq, :string)
      add(:profile, :map)
      add(:version, :integer, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:bap_records, [:txid, :vout]))
    create(index(:bap_records, [:bap_id]))
    create(index(:bap_records, [:address]))
    create(index(:bap_records, [:signer]))
    create(index(:bap_records, [:attestation_hash]))
  end
end
