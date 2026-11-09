defmodule Bitblocks.Chain.TxPipeline.CatchUp do
  @moduledoc """
  Brings a completed block's older rows up to the current versions.

  The sync skips a txid that is already stored (`TxIngest.existing_txids/2`),
  so a row stored by an earlier sync never goes through the chunk steps when
  its block completes: it keeps a nil or old stamp and a nil `block_height`,
  and the block's totals and type counts are left short. `needed?/1` finds
  such a block with one query on the `block_hash` index, and
  `Workers.CatchUpBlockWorker` runs `run/1` off the block lane.

  `run/1` is the backfills over that one block, so there is one way to bring
  a row up to version: script analysis first (everything after needs its
  `coinbase` flag and tags), then the `:tx` steps, then types, then tallies,
  whose block steps rewrite the totals. Each selects what it still lacks, so
  a rerun picks nothing. No `derivation_runs` row: one per block would bury
  the operators' runs. A row skipped by the sync has no stamps at all, so
  `needed?/1` finds the rows the `:tx` steps need too. A tx that doesn't
  decode stays below the version, for the backfills to report.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Block, Transaction, TxPipeline}

  alias Bitblocks.Chain.TxPipeline.{
    Backfill,
    ScriptAnalysisBackfill,
    TxStepsBackfill,
    TxTypesBackfill
  }

  alias Bitblocks.Repo
  alias Bitblocks.Workers.CatchUpBlockWorker

  @doc "True when any of the block's rows is below a current version."
  @spec needed?(Block.t()) :: boolean()
  def needed?(%Block{hash: hash}) do
    analysis = TxPipeline.version(:script_analysis)
    tallies = TxPipeline.version(:tallies)
    types = TxPipeline.version(:tx_types)

    # A tx is typed when its own stamp or its block's is current.
    block_typed? =
      Repo.exists?(from(b in Block, where: b.hash == ^hash and b.tx_types_version == ^types))

    Repo.exists?(
      from(t in Transaction,
        where: t.block_hash == ^hash,
        where:
          is_nil(t.block_height) or
            is_nil(t.script_analysis_version) or t.script_analysis_version < ^analysis or
            is_nil(t.tallies_version) or t.tallies_version < ^tallies or
            (not (^block_typed?) and
               (is_nil(t.tx_types_version) or t.tx_types_version < ^types))
      )
    )
  end

  @doc """
  Enqueues the catch-up when the block needs one. Never raises: a block's
  completion doesn't depend on it, and the backfills report what it missed.
  """
  @spec enqueue(Block.t()) :: :ok
  def enqueue(%Block{} = block) do
    if needed?(block), do: Oban.insert!(CatchUpBlockWorker.new(%{"hash" => block.hash}))
    :ok
  rescue
    e ->
      Logger.error("CatchUp block=#{block.height} not enqueued: #{Exception.message(e)}")
      :ok
  end

  @doc "Runs the backfills over `block`. `:ok`, or the first run's error."
  @spec run(Block.t()) :: :ok | {:error, String.t()}
  def run(%Block{height: height}) do
    opts = [apply: true, record: false, pause_ms: 0]

    [
      &ScriptAnalysisBackfill.run/3,
      &TxStepsBackfill.run/3,
      &TxTypesBackfill.run/3,
      &Backfill.run/3
    ]
    |> Enum.find_value(:ok, fn backfill ->
      case backfill.(height, height, opts) do
        %{outcome: "ok"} -> nil
        %{derivation: derivation, error: error} -> {:error, "#{derivation}: #{error}"}
      end
    end)
  end
end
