defmodule Bitblocks.Repo.Migrations.CreateUsageRollups do
  @moduledoc """
  Hourly usage rollups (`Bitblocks.Usage`, https://github.com/afomi/bitblocks/issues/61):
  what each caller cost us per endpoint class, measured before any rate is set.
  One row per hour, caller and class, summed across nodes; never a row per request.

  The unique index is the upsert's conflict target, and its leading `hour`
  serves the one read, a bounded window of hours. No other index.
  """
  use Ecto.Migration

  def change do
    create table(:usage_rollups) do
      # The start of the UTC hour these counts fall in.
      add(:hour, :utc_datetime, null: false)
      # "key" (an API key), "user" (a signed-in session), "crawler" (an AI
      # crawler family without a key) or "anonymous".
      add(:caller_kind, :text, null: false)
      # The api_keys id, the users id, or the crawler family; "" for anonymous.
      # Never an IP address.
      add(:caller_id, :text, null: false, default: "")
      # read, raw_export, stream, proof, ops or page (Bitblocks.Usage.endpoint_class/1).
      add(:endpoint_class, :text, null: false)

      add(:requests, :bigint, null: false, default: 0)
      add(:status_4xx, :bigint, null: false, default: 0)
      add(:status_5xx, :bigint, null: false, default: 0)
      # Body bytes we sent, chunks of a stream included.
      add(:response_bytes, :bigint, null: false, default: 0)
      # Time from the request reaching the meter to its response's first byte, in microseconds.
      add(:duration_us, :bigint, null: false, default: 0)
      # Ecto's total_time (queue, query, decode) for queries run by the request's process.
      add(:db_us, :bigint, null: false, default: 0)
      add(:db_queries, :bigint, null: false, default: 0)
      # Outbound HTTP calls the request made, by upstream.
      add(:node_calls, :bigint, null: false, default: 0)
      add(:woc_calls, :bigint, null: false, default: 0)
      add(:coingecko_calls, :bigint, null: false, default: 0)
      add(:other_calls, :bigint, null: false, default: 0)
      add(:upstream_us, :bigint, null: false, default: 0)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:usage_rollups, [:hour, :caller_kind, :caller_id, :endpoint_class]))
  end
end
