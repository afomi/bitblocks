defmodule Bitblocks.Chain.TxPipeline.Steps.IndexTimelocks do
  @moduledoc """
  `Timelocks.index/2`: one `timelocks` row per time lock in the tx's output
  scripts (#76), read only from a tx with an output script analysis left
  `unknown`.
  """

  @behaviour Bitblocks.Chain.TxPipeline.Step

  @impl true
  def name, do: "index_timelocks"

  # The step's version lives beside the rows it stamps (Timelocks.version/0).
  # Bump when its output would change; docs/DERIVED_DATA.md.
  @impl true
  def version, do: Bitblocks.Timelocks.version()

  @impl true
  def description,
    do:
      "Logs each script time lock (1Sat Lock, CLTV, CSV), with whether it binds and on which path."

  @impl true
  def stage, do: :tx

  @impl true
  def run(tx, block), do: Bitblocks.Timelocks.index(tx, block)
end
