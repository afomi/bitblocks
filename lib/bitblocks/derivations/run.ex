defmodule Bitblocks.Derivations.Run do
  @moduledoc """
  One backfill run of derived data (`docs/DERIVED_DATA.md`): what it
  derived, at which version, over which heights, what it found and changed,
  whether it applied, and how it ended. Every run writes one, dry runs too.

  `outcome`:

    * `running`: in flight, or the process died before it finished;
    * `ok`: every batch done;
    * `partial`: an error stopped it after at least one batch; those
      batches stay applied, and `error` says what stopped it;
    * `failed`: an error stopped it before any batch finished;
    * `abandoned`: it was `running` when its process died, and an operator
      closed it (`Bitblocks.Derivations.close_abandoned/2`).

  `rows_below_version` is the explicit success check: rows in the range
  still below `version` when the run finished. 0 for a complete applied
  run; for a dry run, how many an apply would stamp.
  """
  use Ecto.Schema

  @outcomes ~w(running ok partial failed abandoned)

  @type t :: %__MODULE__{}

  schema "derivation_runs" do
    # A TxPipeline derivation: "tallies", "script_analysis" or "tx_types", or
    # "tx_steps" (Chain.TxPipeline.TxStepsBackfill) or "tx_size"
    # (Chain.TxSizeBackfill), which have no per-row stamp.
    field :derivation, :string
    # The derivation's version the run brought rows up to.
    field :version, :integer
    # Inclusive block heights; nil for a run over every stored tx.
    field :from_height, :integer
    field :to_height, :integer
    # false for a dry run (writes only this row).
    field :applied, :boolean, default: false
    field :rows_examined, :integer, default: 0
    field :rows_changed, :integer, default: 0
    field :rows_below_version, :integer
    field :blocks_examined, :integer, default: 0
    # Derivation-specific counts.
    field :details, :map, default: %{}
    field :outcome, :string, default: "running"
    field :error, :string
    # The command as typed.
    field :command, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The outcomes a run can have."
  def outcomes, do: @outcomes
end
