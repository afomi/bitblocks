defmodule Bitblocks.Chain.TxPipeline.Steps.IndexCFiles do
  @moduledoc """
  `CFiles.index/2`: one `c_files` row per B:// file in the tx, keyed by the
  sha256 of its bytes, its C:// address
  (https://github.com/afomi/bitblocks/issues/147). Read only from a tx
  tagged `B://`, so it costs nothing on any other tx.
  """

  @behaviour Bitblocks.Chain.TxPipeline.Step

  @impl true
  def name, do: "index_c_files"

  # The step's version lives beside the rows it stamps (CFiles.version/0).
  # Bump when its output would change; docs/DERIVED_DATA.md.
  @impl true
  def version, do: Bitblocks.CFiles.version()

  @impl true
  def description,
    do: "Indexes each B:// file by the sha256 of its bytes, its C:// address."

  @impl true
  def stage, do: :tx

  @impl true
  def run(tx, block), do: Bitblocks.CFiles.index(tx, block)
end
