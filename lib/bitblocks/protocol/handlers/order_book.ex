defmodule Bitblocks.Protocol.Handlers.OrderBook do
  @moduledoc """
  Open Order Book — permissionless BSV-20 marketplace listings.
  Raw OP_RETURN chunks: `"orderbook" <op> <fields...>`.
  Deep parsing delegates to the existing, well-tested `OrderBookParser`.
  """

  use Bitblocks.Protocol.Handler,
    name: "OrderBook",
    exact: "orderbook"

  @impl true
  def parse(data_chunks), do: Bitblocks.OrderBookParser.parse(data_chunks)
end
