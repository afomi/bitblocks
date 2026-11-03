defmodule Bitblocks.Repo.Migrations.CreateChainTiles do
  use Ecto.Migration

  # Precomputed binary tiles for the chain scrubber (#48): one row per
  # (level, idx), ~16 KB a leaf and ~64 KB a bucket tile; about a thousand
  # rows for the whole chain. Durable across deploys (the container's disk is
  # not), content-addressed by `hash`, and served from an ETS copy so a tile
  # request never queries the database. See docs/CHAIN_SCRUBBER.md.
  def change do
    create table(:chain_tiles, primary_key: false) do
      add(:level, :smallint, null: false, primary_key: true)
      add(:idx, :integer, null: false, primary_key: true)
      add(:first_height, :integer, null: false)
      add(:count, :integer, null: false)
      add(:hash, :string, size: 16, null: false)
      add(:bytes, :binary, null: false)
      add(:built_at, :utc_datetime, null: false)
    end

    # One row per build run. The last `ok` row's started_at is the watermark
    # the next incremental build scans blocks.updated_at from.
    create table(:chain_tile_builds) do
      add(:mode, :string, null: false)
      add(:status, :string, null: false)
      add(:started_at, :utc_datetime, null: false)
      add(:finished_at, :utc_datetime)
      add(:tip_height, :integer)
      add(:tiles_written, :integer, default: 0, null: false)
      add(:tiles_unchanged, :integer, default: 0, null: false)
      add(:leaves_scanned, :integer, default: 0, null: false)
      add(:error, :text)
    end

    create(index(:chain_tile_builds, [:status, :started_at]))
  end
end
