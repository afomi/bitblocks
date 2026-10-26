defmodule BitblocksWeb.Api.ProjectionController do
  @moduledoc """
  Managed projections over HTTP (#29, docs/MANAGED_SERVICES.md).

    * `GET /api/v1/projections/:id` — the projection: tenant, filter, hash.
    * `GET /api/v1/projections/:id/txs?cursor=&limit=` — hydrate: confirmed
      history oldest first, frozen at `meta.snapshot_height`. Pass
      `meta.next_cursor` back until it is null. `meta.complete` is false while
      blocks in range are still syncing: the set is partial, so re-hydrate.
    * `GET /api/v1/projections/:id/status` — `index_state` (ready |
      backfilling), `indexed_through_height`, `lag_blocks`, `tip_height`.

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

  def txs(conn, %{"id" => id} = params) do
    opts =
      [cursor: params["cursor"], limit: parse_limit(params["limit"])]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    with {:ok, projection} <- fetch(id),
         {:ok, page} <- Projections.hydrate(projection, opts) do
      json(conn, %{
        data: Enum.map(page.txs, &tx_to_json/1),
        meta: %{
          projection_id: projection.id,
          definition_hash: projection.definition_hash,
          snapshot_height: page.snapshot_height,
          complete: page.complete,
          next_cursor: page.next_cursor
        }
      })
    end
  end

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
      filter: p.filter,
      definition_hash: p.definition_hash,
      from_height: p.from_height,
      status: p.status
    }
  end

  # Raw hex is included so a tenant can fold without a second request; the
  # proof link lets it store a merkle proof alongside each row.
  defp tx_to_json(tx) do
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
end
