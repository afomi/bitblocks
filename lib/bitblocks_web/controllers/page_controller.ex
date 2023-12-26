defmodule BitblocksWeb.PageController do
  use BitblocksWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end

  def status(conn, _params) do
    blockchain_info = BitcoinsvCli.getblockchaininfo()

    if blockchain_info == nil do
      render(conn, "status.html", r: blockchain_info)
    end

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
        headers: headers,
        verificationprogress: verificationprogress
      )
    end

  end

end
