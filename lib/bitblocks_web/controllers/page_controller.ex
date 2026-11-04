defmodule BitblocksWeb.PageController do
  use BitblocksWeb, :controller

  alias BitblocksWeb.Seo

  def index(conn, _params) do
    render(conn, :index)
  end

  def home(conn, _params) do
    seo =
      Seo.public_page(
        page_title: "Bitcoin SV Blockchain Explorer",
        meta_description:
          "Browse Bitcoin SV blocks, transactions, protocols, and live network status with Bitblocks.",
        canonical_path: "/"
      )

    # Recent blocks for the activity feed. The coverage line reads the shared
    # sync snapshot from ETS (Bitblocks.SyncProgress), so it costs no query;
    # the detail lives on /syncing.
    recent_blocks = Bitblocks.Chain.list_blocks(per_page: 7)
    coverage = Bitblocks.SyncProgress.snapshot().overview

    render(
      conn,
      :home,
      Map.merge(seo, %{recent_blocks: recent_blocks, coverage: coverage})
    )
  end

  def applications(conn, _params) do
    render(
      conn,
      "applications.html",
      Seo.public_page(
        page_title: "Applications on Bitcoin SV",
        meta_description:
          "Explore the types of applications Bitblocks supports across Bitcoin SV, from protocol discovery to transaction inspection and DID tooling.",
        canonical_path: "/apps"
      )
    )
  end

  def resources(conn, _params) do
    render(
      conn,
      "resources.html",
      Seo.public_page(
        page_title: "Bitblocks Resources",
        meta_description:
          "Find Bitblocks resources for explorer usage, protocol discovery, source code, deployment notes, and Bitcoin SV learning links.",
        canonical_path: "/resources"
      )
    )
  end

  def status(conn, _params) do
    alias Bitblocks.Chain
    alias Bitblocks.StatsCache

    # Safely attempt to get blockchain info, handling all error cases
    blockchain_info =
      try do
        Bitblocks.RpcCache.get_blockchain_info()
      rescue
        error ->
          require Logger
          Logger.error("Error fetching blockchain info: #{inspect(error)}")
          {:error, error}
      end

    # Use cached counts to avoid slow COUNT(*) queries
    blocks_synced = StatsCache.blocks_count()
    transaction_count = StatsCache.transactions_count()

    # Get latest block and calculate time since last block
    latest_block = Chain.get_latest_block()

    {time_ago_minutes, block_time} =
      if latest_block do
        block_time = DateTime.from_unix!(latest_block.time)
        now = DateTime.utc_now()
        diff_seconds = DateTime.diff(now, block_time)
        minutes_ago = div(diff_seconds, 60)
        {minutes_ago, block_time}
      else
        {nil, nil}
      end

    # The sync's coverage, from the shared /syncing snapshot: an ETS read.
    coverage = Bitblocks.SyncProgress.snapshot().overview

    # The same answer /api/v1/status serves (#44), from cached state.
    health = Bitblocks.Ops.health()

    case blockchain_info do
      %{"blocks" => blocks, "headers" => headers} = info when is_map(info) ->
        %{
          "chain" => chain,
          "pruned" => pruned,
          "verificationprogress" => verificationprogress
        } = info

        # Calculate app sync progress (blocks indexed vs RPC node blocks)
        app_sync_percentage =
          if blocks > 0 do
            (blocks_synced / blocks * 100) |> Float.round(2)
          else
            0.0
          end

        seo =
          Seo.public_page(
            page_title: "Bitcoin SV Node Status",
            meta_description:
              "Monitor Bitblocks sync progress, indexed block counts, transaction totals, and current Bitcoin SV node health.",
            canonical_path: "/status"
          )

        render(
          conn,
          :status,
          Map.merge(seo, %{
            pruned: pruned,
            chain: chain,
            blocks: blocks,
            blocks_synced: blocks_synced,
            coverage: coverage,
            health: health,
            headers: headers,
            verificationprogress: verificationprogress,
            style: %{
              style: "width: #{app_sync_percentage}%;"
            },
            transaction_count: transaction_count,
            latest_block: latest_block,
            time_ago_minutes: time_ago_minutes,
            block_time: block_time
          })
        )

      # Handle any error case (nil, error tuple, or unexpected response)
      _ ->
        render(
          conn,
          :status,
          Map.merge(
            Seo.public_page(
              page_title: "Bitcoin SV Node Status",
              meta_description:
                "Monitor Bitblocks sync progress, indexed block counts, transaction totals, and current Bitcoin SV node health.",
              canonical_path: "/status"
            ),
            %{
              r: nil,
              blocks: nil,
              blocks_synced: blocks_synced,
              coverage: coverage,
              health: health,
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
            }
          )
        )
    end
  end

  def config(conn, _params) do
    # Check if Bitcoin node is configured
    bitcoin_url = Bitblocks.Config.bitcoin_url()
    rpc_user = Application.get_env(:bitblocks, :rpc_user)

    # A public no-auth endpoint (PublicNode) is configured with a URL alone.
    configured = bitcoin_url != nil

    # Try to connect if configured
    connection_status =
      if configured do
        case Bitblocks.Config.node_status(Bitblocks.RpcCache.get_blockchain_info()) do
          :ok -> :success
          {:warming_up, _message} -> :warming_up
          {:unreachable, _reason} -> :error
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
        Bitblocks.RpcCache.get_blockchain_info()
      rescue
        error ->
          require Logger
          Logger.error("Error fetching blockchain info for debug: #{inspect(error)}")
          {:error, error}
      end

    # Get Bitcoin configuration
    bitcoin_url = Bitblocks.Config.bitcoin_url()
    rpc_user = Application.get_env(:bitblocks, :rpc_user)

    render(conn, :debug,
      blockchain_info: blockchain_info_result,
      bitcoin_url: bitcoin_url,
      rpc_user: rpc_user
    )
  end
end
