defmodule BitblocksWeb.Api.OpsMcpController do
  @moduledoc """
  The operator API as MCP tools (#50), so a session can add Bitblocks as an
  MCP server: `POST /api/v1/ops/mcp`, behind the same `ops_read` key.

  Streamable HTTP, stateless: each JSON-RPC request gets one JSON answer, and
  nothing is pushed, so `GET` is a 405. Read tools only; each returns exactly
  what its `/api/v1/ops/*` endpoint returns.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Ops

  @protocol_versions ["2025-06-18", "2025-03-26"]

  @no_arguments %{type: "object", properties: %{}, additionalProperties: false}

  @tools [
    %{
      name: "sync_live",
      description:
        "The sync right now: leader, worker slots, each block's stage and retries, failed blocks with their reasons.",
      inputSchema: @no_arguments
    },
    %{
      name: "block",
      description:
        "One block's story: header, tx counts, sync state, last fetch, errors and reorgs.",
      inputSchema: %{
        type: "object",
        properties: %{height: %{type: "integer", minimum: 0}},
        required: ["height"],
        additionalProperties: false
      }
    },
    %{
      name: "node",
      description:
        "The node: height and headers, RPC and REST latency, and the load our sync puts on it.",
      inputSchema: @no_arguments
    },
    %{
      name: "errors",
      description: "Recent error log lines on this node, with secrets and addresses removed.",
      inputSchema: %{
        type: "object",
        properties: %{limit: %{type: "integer", minimum: 1, maximum: 200}},
        additionalProperties: false
      }
    }
  ]

  # A request with no id is a notification (notifications/initialized): no answer.
  def rpc(conn, %{"jsonrpc" => "2.0", "method" => _} = request)
      when not is_map_key(request, "id") do
    send_resp(conn, 202, "")
  end

  def rpc(conn, %{"jsonrpc" => "2.0", "method" => method, "id" => id} = request) do
    case handle(method, request["params"] || %{}) do
      {:ok, result} -> json(conn, %{jsonrpc: "2.0", id: id, result: result})
      {:error, code, message} -> reply_error(conn, id, code, message)
    end
  end

  def rpc(conn, _params), do: reply_error(conn, nil, -32_600, "Not a JSON-RPC 2.0 request")

  @doc "`GET`: this server pushes nothing, so there is no stream to open."
  def no_stream(conn, _params), do: send_resp(conn, 405, "")

  defp handle("initialize", params) do
    {:ok,
     %{
       protocolVersion: protocol_version(params["protocolVersion"]),
       capabilities: %{tools: %{}},
       serverInfo: %{name: "bitblocks-ops", version: "1"}
     }}
  end

  defp handle("ping", _params), do: {:ok, %{}}
  defp handle("tools/list", _params), do: {:ok, %{tools: @tools}}

  defp handle("tools/call", %{"name" => name} = params) do
    case run_tool(name, params["arguments"] || %{}) do
      {:ok, body} -> {:ok, tool_result(body, false)}
      {:tool_error, message} -> {:ok, tool_result(%{error: message}, true)}
      :unknown -> {:error, -32_602, "Unknown tool"}
    end
  end

  defp handle(_method, _params), do: {:error, -32_601, "Method not found"}

  defp run_tool("sync_live", _args), do: {:ok, Ops.sync_live()}
  defp run_tool("node", _args), do: {:ok, Ops.node_report()}
  defp run_tool("errors", args), do: {:ok, Ops.errors(args["limit"])}

  defp run_tool("block", %{"height" => height}) when is_integer(height) and height >= 0 do
    case Ops.block(height) do
      nil -> {:tool_error, "No stored block at that height"}
      story -> {:ok, story}
    end
  end

  defp run_tool("block", _args), do: {:tool_error, "A block height is a whole number"}
  defp run_tool(_name, _args), do: :unknown

  defp tool_result(body, error?) do
    %{
      content: [%{type: "text", text: Jason.encode!(body)}],
      structuredContent: body,
      isError: error?
    }
  end

  defp protocol_version(asked) when asked in @protocol_versions, do: asked
  defp protocol_version(_), do: hd(@protocol_versions)

  defp reply_error(conn, id, code, message) do
    json(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
  end
end
