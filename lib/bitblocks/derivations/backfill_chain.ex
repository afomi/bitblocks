defmodule Bitblocks.Derivations.BackfillChain do
  @moduledoc """
  A backfill run as Oban jobs, one range at a time (`Bitblocks.BackfillChains`).

  `status`:

    * `running`: a job is working a range, or queued for the next one;
    * `paused`: an operator paused it; the range in flight finished;
    * `cancelled`: an operator stopped it;
    * `done`: every range ran;
    * `failed`: a range kept failing; `error` says why, and it can be resumed.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "derivation_chains" do
    field :derivation, :string
    # false for a dry run.
    field :applied, :boolean, default: false
    # Inclusive; block heights, or tx ids for tx_size.
    field :range_from, :integer
    field :range_to, :integer
    field :range_step, :integer
    # The start of the next range to run.
    field :next_from, :integer
    field :status, :string, default: "running"
    # The backfill's options, as JSON.
    field :opts, :map, default: %{}
    field :error, :string
    # Fresh while a job is alive; nil between jobs.
    field :heartbeat_at, :utc_datetime_usec
    # The highest height (tx id for tx_size) in the range in flight whose
    # batch is committed: a job taking the range starts after it. Saved with
    # the heartbeat after each batch, cleared when the range is done.
    field :checkpoint_height, :integer
    # Set when the batch stopped inside a dense block: the block at
    # checkpoint_height is done only through this transactions.id, and a job
    # taking the range resumes inside it, after this id.
    field :checkpoint_tx_id, :integer
    # When a job last stopped at a batch boundary, its node shutting down,
    # and handed the range on.
    field :handed_off_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    timestamps()
  end
end
