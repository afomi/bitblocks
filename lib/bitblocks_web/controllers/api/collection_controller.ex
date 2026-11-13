defmodule BitblocksWeb.Api.CollectionController do
  @moduledoc """
  1Sat ordinal collections (#30). `:id` is a slug (`grand-tardinians`) or the
  collection's origin outpoint.

    * `GET /api/v1/collections/:id` — item count and trace states.
    * `GET /api/v1/collections/:id/items?cursor=&limit=` — items in mint order.
    * `POST /api/v1/collections/:id/items/lookup` — `{"outpoints": [...]}` (up to
      200): each answered in order from the index, without re-tracing.
    * `GET /api/v1/collections/:id/items/:outpoint[?refresh=1]` — the item at
      `outpoint` (its origin or where it sits now; `_`, `.` or `:` separated).
      `refresh=1` re-traces ownership first if the last trace is over a minute
      old.

  Membership is proven from the mint-contract chain (see
  `Bitblocks.OrdinalCollections`). Each item's `membership` and the
  collection's `verification` say so explicitly (who, on what basis, and a
  pinnable `list_hash`); the MAP `collectionId` is only the chain's claim.

  `spent` and `owner` come from tracing spends: `spent` is null unless the
  trace is settled (`trace_state` `current`, or `ended`, where it is always
  true), so an untraced, partial or unknown trail never reads as "unspent".
  `ownership` carries that claim on its own, apart from `membership`: its
  `owner` is null unless the trace reached the item where it sits now.
  `trace_error` and `trace_checked_at` report a failed last attempt; the
  state and location stay those of the last trace that answered.

  `member` is `true`, `false`, or `"unknown"`. `false` needs a finished chain
  walk and every trace settled, `current` or `ended` (see
  `OrdinalCollections.absence/2`).
  """
  use BitblocksWeb, :controller

  alias Bitblocks.OrdinalCollections

  action_fallback BitblocksWeb.FallbackController

  @refresh_after_seconds 60

  def show(conn, %{"id" => id}) do
    with {:ok, cid} <- collection(id) do
      data =
        cid
        |> OrdinalCollections.summary()
        |> Map.merge(%{collection_id: cid, verification: OrdinalCollections.verification(cid)})

      json(conn, %{data: data})
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
    outpoint = normalize(raw_outpoint)

    with {:ok, cid} <- collection(id) do
      case OrdinalCollections.get_item(cid, outpoint) do
        nil ->
          {member, reason} = OrdinalCollections.absence(cid, [outpoint])[outpoint]

          conn
          |> put_status(:not_found)
          |> json(%{member: member, reason: reason})

        item ->
          item = maybe_refresh(item, params["refresh"])
          json(conn, %{data: item |> item_json() |> Map.merge(presented(item, outpoint))})
      end
    end
  end

  @max_lookup 200

  def lookup(conn, %{"id" => id, "outpoints" => outpoints})
      when is_list(outpoints) and length(outpoints) <= @max_lookup do
    with {:ok, cid} <- collection(id) do
      asked = Enum.map(outpoints, &normalize/1)
      found = OrdinalCollections.lookup(cid, asked)
      absent = OrdinalCollections.absence(cid, Enum.reject(asked, &found[&1]))

      data =
        for outpoint <- asked do
          case found[outpoint] do
            nil ->
              {member, reason} = absent[outpoint]
              %{outpoint: outpoint, member: member, reason: reason}

            item ->
              item |> item_json() |> Map.merge(presented(item, outpoint))
          end
        end

      json(conn, %{data: data, meta: %{collection_id: cid}})
    end
  end

  def lookup(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "Expected {\"outpoints\": [outpoint, …]} with at most #{@max_lookup} entries"
    })
  end

  defp normalize(outpoint) when is_binary(outpoint), do: String.replace(outpoint, ~r/[.:]/, "_")
  defp normalize(other), do: to_string(other)

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
      case OrdinalCollections.trace(item) do
        {:ok, traced} -> traced
        # A reorg removed it mid-trace; answer from what we read.
        {:error, :gone} -> item
      end
    else
      item
    end
  end

  defp maybe_refresh(item, _), do: item

  defp presented(item, outpoint) do
    %{
      outpoint: outpoint,
      member: true,
      spent:
        case item.trace_state do
          "current" -> outpoint != item.current_outpoint
          "ended" -> true
          _ -> nil
        end
    }
  end

  defp item_json(item) do
    item
    |> Map.take([
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
      :traced_at,
      :trace_error,
      :trace_checked_at,
      :trail
    ])
    |> Map.put(:membership, %{
      verified: true,
      by: "bitblocks",
      basis: "mint_contract_chain",
      chain_from: item.collection_id,
      mint_txid: item.mint_txid,
      claim: "MAP subTypeData.collectionId"
    })
    |> Map.put(:ownership, %{
      owner: if(item.trace_state == "current", do: item.owner),
      state: item.trace_state,
      reason: item.trace_reason,
      source: item.trace_source,
      traced_at: item.traced_at
    })
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
