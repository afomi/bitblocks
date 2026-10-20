defmodule Bitblocks.Repo.Migrations.AddOwnershipProofToProtocols do
  use Ecto.Migration

  # On-chain proof that a protocol's prefix address is controlled by whoever
  # registered it: the txid of a Bitcom `$ useradd <address>` spent from
  # <address>. Separate from verification_status, which is curation (seeded
  # or reviewed), not proof.
  def change do
    alter table(:protocols) do
      add(:ownership_proof_txid, :string)
    end
  end
end
