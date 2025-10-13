defmodule Bitblocks.Chain.Block do
  use Ecto.Schema

  use Machinery,
    # State machine field
    field: :sync_state,
    # All possible states
    states: ~w(pending header_synced txs_queued txs_syncing completed failed),
    # State transitions
    transitions: %{
      pending: [:header_synced],
      # completed if block has 0 txs
      header_synced: [:txs_queued, :completed],
      txs_queued: [:txs_syncing],
      txs_syncing: [:completed, :failed],
      # retry
      failed: [:txs_queued]
    }

  import Ecto.Changeset

  @sync_states ~w(pending header_synced txs_queued txs_syncing completed failed)

  schema "blocks" do
    field :size, :integer
    field :timestamp, :naive_datetime
    field :version, :integer
    field :time, :integer
    field :bits, :string
    field :hash, :string
    field :num_tx, :integer
    field :chainwork, :string
    field :difficulty, :string
    field :height, :integer
    field :mediantime, :integer
    field :merkleroot, :string
    field :nextblockhash, :string
    field :prevblockhash, :string
    field :nonce, :integer
    field :tx, {:array, :string}

    # Sync state machine fields
    field :sync_state, :string, default: "pending"
    field :tx_sync_started_at, :utc_datetime
    field :tx_sync_completed_at, :utc_datetime
    field :tx_sync_error, :string
    field :tx_sync_attempts, :integer, default: 0

    timestamps()
  end

  @doc false
  def changeset(block, attrs) do
    block
    |> cast(attrs, [
      :hash,
      :num_tx,
      :timestamp,
      :bits,
      :chainwork,
      :difficulty,
      :height,
      :mediantime,
      :merkleroot,
      :nextblockhash,
      :prevblockhash,
      :nonce,
      :size,
      :time,
      :version,
      :tx,
      :sync_state,
      :tx_sync_started_at,
      :tx_sync_completed_at,
      :tx_sync_error,
      :tx_sync_attempts
    ])
    |> validate_required([:hash, :height])
    |> validate_inclusion(:sync_state, @sync_states)
  end

  @doc """
  State transition changeset using Machinery.

  Valid transitions (managed by Machinery):
  - pending -> header_synced (block header downloaded)
  - header_synced -> txs_queued (transaction download job queued)
  - header_synced -> completed (skip tx download if block has 0 txs)
  - txs_queued -> txs_syncing (transaction download started)
  - txs_syncing -> completed (all transactions downloaded)
  - txs_syncing -> failed (transaction download failed)
  - failed -> txs_queued (retry transaction download)

  Use Machinery.transition_to/2 to transition states.
  """
  def transition_changeset(block, new_state, attrs \\ %{}) do
    attrs =
      case new_state do
        "txs_syncing" ->
          Map.put(attrs, :tx_sync_started_at, DateTime.utc_now())

        "completed" ->
          Map.put(attrs, :tx_sync_completed_at, DateTime.utc_now())

        "failed" ->
          attrs
          |> Map.put(:tx_sync_error, Map.get(attrs, :error))
          |> Map.update(:tx_sync_attempts, 1, &(&1 + 1))

        _ ->
          attrs
      end

    changeset(block, attrs)
  end

  # Machinery callbacks for state transitions
  def before_transition(%{sync_state: "txs_queued"}, "txs_syncing"), do: :ok
  def before_transition(_struct, _next_state), do: :ok

  def after_transition(%{sync_state: "completed"} = block, _prev_state) do
    # Could broadcast event or trigger notifications here
    {:ok, block}
  end

  def after_transition(block, _prev_state), do: {:ok, block}

  def persist_callback(struct, _next_state) do
    # Machinery calls this to persist the state change
    # We'll handle persistence in the Chain context
    {:ok, struct}
  end
end
