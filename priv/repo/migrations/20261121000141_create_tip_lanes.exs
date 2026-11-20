defmodule Bitblocks.Repo.Migrations.CreateTipLanes do
  use Ecto.Migration

  # #139: a tip lane keeps one projection's slice of the chain current at the
  # tip, ahead of the contiguous sync (Bitblocks.TipLane, docs/SYNCING.md).
  # Both tables are small: one lane per projection, and one row per block the
  # lane has read (an election is a few thousand blocks). Nothing is added to
  # `transactions` or `blocks`.
  def change do
    create table(:tip_lanes) do
      add(:projection_id, references(:projections, on_delete: :delete_all), null: false)
      # The first block the lane reads; blocks below it are the sync's.
      add(:from_height, :integer, null: false)
      # Operator intent: running | stopped. How far it reaches is computed
      # from tip_lane_blocks and blocks, never stored.
      add(:status, :string, null: false, default: "running")
      add(:started_at, :utc_datetime)
      add(:stopped_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:tip_lanes, [:projection_id]))

    create table(:tip_lane_blocks) do
      add(:projection_id, references(:projections, on_delete: :delete_all), null: false)
      # The block read, and its hash then: a row whose hash no longer matches
      # the header at its height (a reorg) is rewound and read again.
      add(:height, :integer, null: false)
      add(:block_hash, :string, null: false)
      # read | reading | failed; only read rows count toward coverage.
      add(:status, :string, null: false, default: "reading")
      # The txs the lane kept from the block: matches, then spends of the
      # slice's outputs. A rewind removes these, and only these.
      add(:txids, {:array, :string}, null: false, default: [])
      add(:matched, :integer, null: false, default: 0)
      add(:spends, :integer, null: false, default: 0)
      # How the block was read: rest | rpc | rest_stream.
      add(:source, :string)
      add(:error, :text)
      add(:attempts, :integer, null: false, default: 0)
      add(:started_at, :utc_datetime)
      add(:read_at, :utc_datetime)
    end

    create(unique_index(:tip_lane_blocks, [:projection_id, :height]))
  end
end
