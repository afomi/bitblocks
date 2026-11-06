defmodule Bitblocks.Chain.TxPipeline.Steps.IndexBap do
  @moduledoc "`Bap.index/1`: BAP records with a valid AIP signature; a no-op on a tx with no AIP signer."

  @behaviour Bitblocks.Chain.TxPipeline.Step

  @impl true
  def name, do: "index_bap"

  # Bump when this step's output would change; docs/DERIVED_DATA.md.
  @impl true
  def version, do: 1

  @impl true
  def description, do: "Logs BAP identity records (txs with a valid AIP signature only)."

  @impl true
  def stage, do: :tx

  @impl true
  def run(tx, _block), do: Bitblocks.Bap.index(tx)
end
