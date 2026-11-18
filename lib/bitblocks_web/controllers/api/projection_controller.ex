defmodule BitblocksWeb.Api.ProjectionController do
  @moduledoc """
  Managed projections over HTTP (#29, docs/MANAGED_SERVICES.md).

    * `GET /api/v1/projections/:id` — the projection: tenant, filter, hash.
    * `GET /api/v1/projections/:id/txs?cursor=&limit=` — hydrate: confirmed
      history oldest first, frozen at `meta.snapshot_height`. Pass
      `meta.next_cursor` back until it is null. `meta.complete` is true while
      a page lies within `meta.stable_through_height`; when it turns false,
      hold that cursor and come back, because rows above are not yet final.
    * `GET /api/v1/projections/:id/commands?cursor=&limit=` — hydrate for a
      `bitcom_commands` projection (Tenant 3): the Bitcom command log, in
      `(block_height, txid, output_index)` order, with the same meta.
      Each path answers a 400 naming the other for the wrong source.
    * `GET /api/v1/projections/:id/status` — `index_state` (ready |
      backfilling), `stable_through_height`, `lag_blocks`, `tip_height`,
      `node_tip_height`.
    * `GET /api/v1/projections/:id/follow` — SSE follow from a block height,
      served by `BitblocksWeb.Api.StreamController.projection/2`.

  Projections are registered from the CLI (`Release.create_projection/1`)
  until tenant keys exist (#29 step 5). Matching txs are public chain data.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Projections

  action_fallback BitblocksWeb.FallbackController

  def show(conn, %{"id" => id}) do
    with {:ok, projection} <- fetch(id) do
      json(conn, %{data: projection_to_json(projection)})
    end
  end

  def txs(conn, %{"id" => id} = params),
    do: hydrate(conn, id, params, "transactions", :txs, &tx_to_json/1)

  def commands(conn, %{"id" => id} = params),
    do: hydrate(conn, id, params, "bitcom_commands", :commands, &command_to_json/1)

  defp hydrate(conn, id, params, source, key, to_json) do
    opts =
      [cursor: params["cursor"], limit: parse_limit(params["limit"])]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    with {:ok, projection} <- fetch(id),
         :ok <- same_source(projection, source),
         {:ok, page} <- Projections.hydrate(projection, opts) do
      json(conn, %{
        data: Enum.map(Map.fetch!(page, key), to_json),
        meta: %{
          projection_id: projection.id,
          source: projection.source,
          definition_hash: projection.definition_hash,
          snapshot_height: page.snapshot_height,
          stable_through_height: page.stable_through_height,
          complete: page.complete,
          next_cursor: page.next_cursor
        }
      })
    else
      {:wrong_source, path} ->
        conn
        |> put_status(400)
        |> json(%{error: "This projection is hydrated at #{path}", hydrate: path})

      other ->
        other
    end
  end

  defp same_source(%{source: source}, source), do: :ok
  defp same_source(projection, _source), do: {:wrong_source, hydrate_path(projection)}

  @doc false
  def hydrate_path(%{id: id, source: "bitcom_commands"}), do: "/api/v1/projections/#{id}/commands"
  def hydrate_path(%{id: id}), do: "/api/v1/projections/#{id}/txs"

  def status(conn, %{"id" => id}) do
    with {:ok, projection} <- fetch(id) do
      json(conn, %{data: Projections.status(projection)})
    end
  end

  defp fetch(id) do
    with {id, ""} <- Integer.parse(id),
         %{} = projection <- Projections.get(id) do
      {:ok, projection}
    else
      _ -> {:error, :not_found}
    end
  end

  defp parse_limit(nil), do: nil

  defp parse_limit(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp projection_to_json(p) do
    %{
      id: p.id,
      tenant: p.tenant,
      name: p.name,
      source: p.source,
      filter: p.filter,
      definition_hash: p.definition_hash,
      from_height: p.from_height,
      status: p.status,
      # Where to hydrate, so a client needn't branch on `source`.
      hydrate_url: hydrate_path(p)
    }
  end

  # Raw hex is included so a tenant can fold without a second request; the
  # proof link lets it store a merkle proof alongside each row.
  @doc false
  def tx_to_json(tx) do
    %{
      txid: tx.txid,
      block_height: tx.block_height,
      block_hash: tx.block_hash,
      raw: tx.raw,
      output_addresses: tx.output_addresses,
      protocols: tx.protocols,
      aip_signers: tx.aip_signers,
      proof_url: "/api/v1/txs/#{tx.txid}/proof"
    }
  end

  # One logged Bitcom command (Tenant 3), valid or not: a fork of the registry
  # can reinterpret the rejections too. `actor` funded the tx; `namespace` is
  # the address the command applies to (docs/BITCOM.md).
  @doc false
  def command_to_json(c) do
    %{
      txid: c.txid,
      output_index: c.output_index,
      block_height: c.block_height,
      block_hash: c.block_hash,
      actor: c.actor,
      namespace: c.namespace,
      command: c.command,
      args: c.args,
      file: c.file,
      content: c.content,
      locator: c.locator,
      route_matcher: c.route_matcher,
      endpoint: c.endpoint,
      valid: c.valid,
      reason: c.reason,
      proof_url: "/api/v1/txs/#{c.txid}/proof"
    }
  end
end
