defmodule BitblocksWeb.PageController do
  use BitblocksWeb, :controller
  alias Bitblocks.Repo

  def index(conn, _params) do
    render(conn, :index)
  end

  def home(conn, _params) do
    alias Bitblocks.Chain

    # Get latest block and total count
    latest_block = Chain.get_latest_block()
    total_blocks = Chain.count_blocks()

    # Calculate time since last block if we have one
    {time_ago_minutes, block_time} = if latest_block do
      block_time = DateTime.from_unix!(latest_block.time)
      now = DateTime.utc_now()
      diff_seconds = DateTime.diff(now, block_time)
      minutes_ago = div(diff_seconds, 60)
      {minutes_ago, block_time}
    else
      {nil, nil}
    end

    # Get blockchain info from RPC node
    blockchain_info = get_blockchain_info()
    transactions_count = Repo.aggregate(Bitblocks.Chain.Transaction, :count, :id)

    render(conn, :home,
      latest_block: latest_block,
      total_blocks: total_blocks,
      time_ago_minutes: time_ago_minutes,
      block_time: block_time,
      blockchain_info: blockchain_info,
      blocks_count: total_blocks,
      transactions_count: transactions_count
    )
  end

  defp get_blockchain_info do
    try do
      case BitcoinsvCli.getblockchaininfo() do
        %{"blocks" => blocks, "headers" => headers, "chain" => chain, "verificationprogress" => verificationprogress} ->
          %{
            chain: chain,
            blocks: blocks,
            headers: headers,
            verificationprogress: verificationprogress,
            synced: blocks == headers
          }

        _ ->
          nil
      end
    rescue
      _ -> nil
    end
  end

  def applications(conn, _params) do
    render(conn, "applications.html")
  end

  def resources(conn, _params) do
    render(conn, "resources.html")
  end

  def status(conn, _params) do
    alias Bitblocks.Chain

    # Safely attempt to get blockchain info, handling all error cases
    blockchain_info =
      try do
        BitcoinsvCli.getblockchaininfo()
      rescue
        error ->
          require Logger
          Logger.error("Error fetching blockchain info: #{inspect(error)}")
          {:error, error}
      end

    blocks_synced = Repo.aggregate(Bitblocks.Chain.Block, :count, :id)
    transaction_count = Repo.aggregate(Bitblocks.Chain.Transaction, :count, :id)

    # Get latest block and calculate time since last block
    latest_block = Chain.get_latest_block()
    {time_ago_minutes, block_time} = if latest_block do
      block_time = DateTime.from_unix!(latest_block.time)
      now = DateTime.utc_now()
      diff_seconds = DateTime.diff(now, block_time)
      minutes_ago = div(diff_seconds, 60)
      {minutes_ago, block_time}
    else
      {nil, nil}
    end

    case blockchain_info do
      %{"blocks" => blocks, "headers" => headers} = info when is_map(info) ->
        %{
          "chain" => chain,
          "pruned" => pruned,
          "verificationprogress" => verificationprogress
        } = info

        # Calculate app sync progress (blocks indexed vs RPC node blocks)
        app_sync_percentage = if blocks > 0 do
          (blocks_synced / blocks * 100) |> Float.round(2)
        else
          0.0
        end

        render(conn, :status,
          pruned: pruned,
          chain: chain,
          blocks: blocks,
          blocks_synced: blocks_synced,
          headers: headers,
          verificationprogress: verificationprogress,
          style: %{
            style: "width: #{app_sync_percentage}%;"
          },
          transaction_count: transaction_count,
          latest_block: latest_block,
          time_ago_minutes: time_ago_minutes,
          block_time: block_time
        )

      # Handle any error case (nil, error tuple, or unexpected response)
      _ ->
        render(conn, :status,
          r: nil,
          blocks: nil,
          blocks_synced: blocks_synced,
          transaction_count: transaction_count,
          style: %{
            style: "width: 0;"
          },
          chain: nil,
          headers: nil,
          verificationprogress: 0.0,
          pruned: nil,
          latest_block: nil,
          time_ago_minutes: nil,
          block_time: nil
        )
    end
  end

  def config(conn, _params) do
    # Check if Bitcoin node is configured
    bitcoin_url = Application.get_env(:bitblocks, :bitcoin_url)
    rpc_user = Application.get_env(:bitblocks, :rpc_user)
    rpc_password = Application.get_env(:bitblocks, :rpc_password)

    configured = bitcoin_url != nil && rpc_user != nil && rpc_password != nil

    # Try to connect if configured
    connection_status =
      if configured do
        case BitcoinsvCli.getblockchaininfo() do
          %{"chain" => _} -> :success
          {:error, _reason} -> :error
          nil -> :error
          _ -> :error
        end
      else
        :not_configured
      end

    render(conn, :config,
      bitcoin_url: bitcoin_url,
      rpc_user: rpc_user,
      configured: configured,
      connection_status: connection_status
    )
  end

  def debug(conn, _params) do
    # Safely attempt to get blockchain info, handling all error cases
    blockchain_info_result =
      try do
        BitcoinsvCli.getblockchaininfo()
      rescue
        error ->
          require Logger
          Logger.error("Error fetching blockchain info for debug: #{inspect(error)}")
          {:error, error}
      end

    # Get Bitcoin configuration
    bitcoin_url = Application.get_env(:bitblocks, :bitcoin_url)
    rpc_user = Application.get_env(:bitblocks, :rpc_user)

    render(conn, :debug,
      blockchain_info: blockchain_info_result,
      bitcoin_url: bitcoin_url,
      rpc_user: rpc_user
    )
  end
end
