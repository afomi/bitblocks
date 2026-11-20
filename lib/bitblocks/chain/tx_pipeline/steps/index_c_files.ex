defmodule Bitblocks.Chain.TxPipeline.Steps.IndexCFiles do
  @moduledoc """
  `CFiles.index/2`: one `c_files` row per B:// file in the tx, keyed by the
  sha256 of its bytes, its C:// address
  (https://github.com/afomi/bitblocks/issues/147). Read only from a tx
  tagged `B://`, so it costs nothing on any other tx.

  v2 (https://github.com/afomi/bitblocks/issues/155): a tx tagged BCat, a
  head naming a file's chunks, enqueues `Workers.CFileBcatWorker`, which
  assembles the file off the insert and indexes it by the sha256 of the
  whole file. Nothing is assembled inline.
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
    do:
      "Indexes each B:// file by the sha256 of its bytes, its C:// address, " <>
        "and queues each BCat head's file to be assembled and indexed by the sha256 of the whole file."

  @impl true
  def stage, do: :tx

  @impl true
  def run(tx, block), do: Bitblocks.CFiles.index(tx, block)
end
