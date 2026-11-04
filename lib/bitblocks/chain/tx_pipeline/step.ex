defmodule Bitblocks.Chain.TxPipeline.Step do
  @moduledoc """
  One step of `Bitblocks.Chain.TxPipeline`. A step is a small module that
  names itself, says in one line what it does, and runs at one stage:

    * `:chunk`: before the insert, over a chunk of a block's txs in block
      order. `run_chunk(attrs_list, block)` returns the attrs with its
      columns added, so they go in with the insert and no row is updated
      after it.
    * `:tx`: after the insert, once per stored tx. `run(tx, block)`.
    * `:block`: once, when the block becomes `completed`. `run_block(block)`.

  A step that raises is logged and reported by the pipeline; it never loses
  the stored tx or decides whether the block completes.

  Every step has a `version/0`, a positive integer bumped whenever its
  output for the same input would change. The pipeline sums them into the
  versions stamped on each row (`TxPipeline.version/1`), so a bump marks
  every row computed before it as below the version, which is what a
  backfill picks up (`docs/DERIVED_DATA.md`).
  """

  alias Bitblocks.Chain.{Block, Transaction}

  @type stage :: :chunk | :tx | :block

  @doc "The step's name, as `docs/TX_PIPELINE.md` lists it."
  @callback name() :: String.t()

  @doc "What the step does, in one line."
  @callback description() :: String.t()

  @callback stage() :: stage()

  @doc "The step's version: bump it whenever its output would change."
  @callback version() :: pos_integer()

  @callback run_chunk([map()], Block.t()) :: [map()]
  @callback run(Transaction.t(), Block.t()) :: term()
  @callback run_block(Block.t()) :: term()

  @optional_callbacks run_chunk: 2, run: 2, run_block: 1
end
