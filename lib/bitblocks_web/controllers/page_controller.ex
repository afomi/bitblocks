defmodule BitblocksWeb.PageController do
  use BitblocksWeb, :controller
  alias Bitblocks.Repo

  def index(conn, _params) do
    render(conn, "index.html")
  end

  def applications(conn, _params) do
    render(conn, "applications.html")
  end

  def resources(conn, _params) do
    render(conn, "resources.html")
  end

  def status(conn, _params) do
    blockchain_info = BitcoinsvCli.getblockchaininfo()

    if blockchain_info == nil do
      render(conn, "status.html", r: blockchain_info)
    end

    blocks_synced = Repo.aggregate(Bitblocks.Block, :count, :id)


    if blockchain_info |> is_map do
      %{
        "bestblockhash" => bestblockhash,
        "blocks" => blocks,
        "chain" => chain,
        "chainwork" => chainwork,
        "difficulty" => difficulty,
        "headers" => headers,
        "mediantime" => mediantime,
        "pruned" => pruned,
        "softforks" => softforks,
        "verificationprogress" => verificationprogress,
      } = blockchain_info

      render(conn, "status.html",
        pruned: pruned,
        chain: chain,
        blocks: blocks,
        blocks_synced: blocks_synced,
        headers: headers,
        verificationprogress: verificationprogress,
        style: %{
          style: "width: #{Float.to_string((blocks / headers) * 100)}%;"
        }
      )
    end

  end

end
