defmodule BitblocksWeb.WallController do
  use BitblocksWeb, :controller

  def index(conn, _params) do
    render(conn, :index)
  end

  def blocks_data(conn, _params) do
    # Return a stream of block data for visualization
    # We'll paginate this to avoid loading all 900k blocks at once
    limit = String.to_integer(conn.params["limit"] || "10000")
    offset = String.to_integer(conn.params["offset"] || "0")

    blocks = Bitblocks.Chain.list_blocks(page: div(offset, limit) + 1, per_page: limit)

    # Return minimal data for performance
    block_data =
      Enum.map(blocks, fn block ->
        %{
          height: block.height,
          hash: block.hash,
          time: block.time,
          num_tx: block.num_tx,
          size: block.size
        }
      end)

    total_count = Bitblocks.Chain.count_blocks()

    json(conn, %{
      blocks: block_data,
      total: total_count,
      offset: offset,
      limit: limit
    })
  end
end
