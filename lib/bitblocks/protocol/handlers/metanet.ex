defmodule Bitblocks.Protocol.Handlers.Metanet do
  @moduledoc """
  Metanet — DAG of on-chain nodes.
  Raw OP_RETURN chunks: `"meta" <P_node> <TxID_parent> [<name>] [...]`.
  Deep parsing delegates to the existing, well-tested `MetanetParser`.
  """

  use Bitblocks.Protocol.Handler,
    name: "Metanet",
    exact: "meta"

  @impl true
  def parse(data_chunks), do: Bitblocks.MetanetParser.parse(data_chunks)
end
