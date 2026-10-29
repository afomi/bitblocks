defmodule BitblocksWeb.Api.CollectionController do
  @moduledoc """
  1Sat ordinal collections (#30). `:id` is a slug (`grand-tardinians`) or the
  collection's origin outpoint.

    * `GET /api/v1/collections/:id` — item count and trace states.
    * `GET /api/v1/collections/:id/items?cursor=&limit=` — items in mint order.
    * `GET /api/v1/collections/:id/items/:outpoint[?refresh=1]` — the item at
      `outpoint` (its origin or where it sits now; `_`, `.` or `:` separated).
      `refresh=1` re-traces ownership first if the last trace is over a minute
      old.

  Membership is proven from the mint-contract chain (see
  `Bitblocks.OrdinalCollections`). `spent` and `owner` come from tracing
  spends: `spent` is null unless `trace_state` is `current`, so an untraced or
  unknown trail never reads as "unspent".
  """
  use BitblocksWeb, :controller

  alias Bitblocks.OrdinalCollections

  action_fallback BitblocksWeb.FallbackController

  @refresh_after_seconds 60

  def show(conn, %{"id" => id}) do
    with {:ok, cid} <- collection(id) do
      json(conn, %{data: Map.put(OrdinalCollections.summary(cid), :collection_id, cid)})
    end
  end

  def items(conn, %{"id" => id} = params) do
    with {:ok, cid} <- collection(id) do
      page =
        OrdinalCollections.list_items(cid,
          cursor: parse_int(params["cursor"]),
          limit: parse_int(params["limit"]) || 100
        )

      json(conn, %{
        data: Enum.map(page.items, &item_json/1),
        meta: %{collection_id: cid, next_cursor: page.next_cursor}
      })
    end
  end

  def item(conn, %{"id" => id, "outpoint" => raw_outpoint} = params) do
    outpoint = String.replace(raw_outpoint, ~r/[.:]/, "_")

    with {:ok, cid} <- collection(id) do
      case OrdinalCollections.get_item(cid, outpoint) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{
            member: "unknown",
            reason: "not an indexed item of this collection (or its sync is incomplete)"
          })

        item ->
          item = maybe_refresh(item, params["refresh"])
          json(conn, %{data: item |> item_json() |> Map.merge(presented(item, outpoint))})
      end
    end
  end

  defp collection(id) do
    case OrdinalCollections.resolve(id) do
      nil -> {:error, :not_found}
      cid -> {:ok, cid}
    end
  end

  defp maybe_refresh(item, "1") do
    stale? =
      is_nil(item.traced_at) or
        DateTime.diff(DateTime.utc_now(), item.traced_at) > @refresh_after_seconds

    if stale? do
      {:ok, traced} = OrdinalCollections.trace(item)
      traced
    else
      item
    end
  end

  defp maybe_refresh(item, _), do: item

  defp presented(item, outpoint) do
    %{
      outpoint: outpoint,
      member: true,
      spent: if(item.trace_state == "current", do: outpoint != item.current_outpoint)
    }
  end

  defp item_json(item) do
    Map.take(item, [
      :origin,
      :name,
      :traits,
      :content_type,
      :mint_txid,
      :mint_height,
      :current_outpoint,
      :owner,
      :trace_state,
      :trace_reason,
      :trace_source,
      :traced_at
    ])
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
