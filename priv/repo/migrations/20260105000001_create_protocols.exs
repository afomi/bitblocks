defmodule Bitblocks.Repo.Migrations.CreateProtocols do
  use Ecto.Migration

  def change do
    # Protocol categories enum
    create_query = """
    CREATE TYPE protocol_category AS ENUM (
      'consumable',
      'multi_party',
      'constraint',
      'bearer_asset',
      'access_control',
      'credential',
      'data_storage',
      'identity',
      'token',
      'other'
    )
    """
    drop_query = "DROP TYPE protocol_category"
    execute(create_query, drop_query)

    # Verification status enum
    create_query = """
    CREATE TYPE verification_status AS ENUM (
      'unverified',
      'pending',
      'beta',
      'verified',
      'deprecated'
    )
    """
    drop_query = "DROP TYPE verification_status"
    execute(create_query, drop_query)

    # Main protocols table
    create table(:protocols) do
      # Identity: Bitcom-style Bitcoin address
      add :address, :string, null: false
      add :name, :string, null: false
      add :version, :integer, null: false, default: 1
      add :description, :text

      # Classification
      add :category, :protocol_category, null: false, default: "other"
      add :verification_status, :verification_status, null: false, default: "unverified"

      # Schema definition (JSON)
      add :schema, :map

      # Covenant enforcement
      add :has_covenant, :boolean, default: false
      add :covenant_hash, :string
      add :scrypt_source, :text

      # Metadata
      add :author, :string
      add :documentation_url, :string
      add :source_url, :string
      add :example_txid, :string

      # Compatibility
      add :requires, {:array, :string}, default: []
      add :conflicts_with, {:array, :string}, default: []

      timestamps()
    end

    create unique_index(:protocols, [:address, :version])
    create unique_index(:protocols, [:name, :version])
    create index(:protocols, [:category])
    create index(:protocols, [:verification_status])
    create index(:protocols, [:has_covenant])

    # Protocol statistics table
    create table(:protocol_stats) do
      add :protocol_id, references(:protocols, on_delete: :delete_all), null: false
      add :period, :string, null: false  # "all_time", "daily", "weekly", "monthly"
      add :period_start, :date

      # Counters
      add :instance_count, :bigint, default: 0
      add :transaction_count, :bigint, default: 0
      add :unique_addresses, :bigint, default: 0
      add :total_satoshis, :bigint, default: 0

      # First/last seen
      add :first_seen_txid, :string
      add :first_seen_at, :utc_datetime
      add :last_seen_txid, :string
      add :last_seen_at, :utc_datetime

      timestamps()
    end

    create unique_index(:protocol_stats, [:protocol_id, :period, :period_start])
    create index(:protocol_stats, [:period])
    create index(:protocol_stats, [:instance_count])

    # Protocol audits table
    create table(:protocol_audits) do
      add :protocol_id, references(:protocols, on_delete: :delete_all), null: false
      add :auditor, :string, null: false
      add :audit_type, :string, null: false  # "security", "spec_compliance", "interop"
      add :result, :string, null: false  # "pass", "fail", "warning"
      add :notes, :text
      add :report_url, :string
      add :audit_date, :date, null: false

      timestamps()
    end

    create index(:protocol_audits, [:protocol_id])
    create index(:protocol_audits, [:audit_type])
    create index(:protocol_audits, [:result])

    # Protocol instances table (individual occurrences on-chain)
    create table(:protocol_instances) do
      add :protocol_id, references(:protocols, on_delete: :delete_all), null: false
      add :txid, :string, null: false
      add :vout, :integer, null: false
      add :block_height, :integer
      add :block_hash, :string

      # Parsed data from the OP_RETURN
      add :parsed_data, :map

      # State tracking for stateful protocols
      add :state, :map
      add :spent, :boolean, default: false
      add :spent_txid, :string

      timestamps()
    end

    create unique_index(:protocol_instances, [:txid, :vout])
    create index(:protocol_instances, [:protocol_id])
    create index(:protocol_instances, [:block_height])
    create index(:protocol_instances, [:spent])
  end
end
