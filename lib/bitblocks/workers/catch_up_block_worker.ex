defmodule Bitblocks.Workers.CatchUpBlockWorker do
  @moduledoc """
  Runs `Chain.TxPipeline.CatchUp` for one completed block, on its own lane
  (`:derived`, concurrency 1), so a block full of older rows never holds up a
  sync slot. Unique on the block hash, and safe to repeat: the work selects
  by version, so a retry or a rescue after a restart picks up what's left.

  A block with several hundred thousand older rows can outlast Lifeline's
  `rescue_after`; the second run then writes the same values.
  """

  use Oban.Worker,
    queue: :derived,
    max_attempts: 5,
    unique: [period: 3600, fields: [:args], keys: [:hash]]

  alias Bitblocks.Chain.Block
  alias Bitblocks.Chain.TxPipeline.CatchUp
  alias Bitblocks.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"hash" => hash}}) do
    case Repo.get_by(Block, hash: hash) do
      %Block{sync_state: "completed"} = block -> CatchUp.run(block)
      _ -> {:cancel, :block_not_completed}
    end
  end
end
