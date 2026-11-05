defmodule BitblocksWeb.Api.AnnotationController do
  @moduledoc """
  Admin CRUD for chain annotations (`Bitblocks.Annotations`).

      GET    /api/v1/annotations        every annotation in chain order (?from=&to= by height, ?kind=)
      GET    /api/v1/annotations/:id
      POST   /api/v1/annotations        {"annotation": {...}} or the fields at the top level
      PATCH  /api/v1/annotations/:id
      DELETE /api/v1/annotations/:id

  Admin only (`:admin_data`); writes must be
  `application/json` (`BitblocksWeb.Plugs.RequireJsonBody`).
  Fields: `kind`, `title`, `body`, `source_url`, and at least one anchor of
  `height`, `txid` or `occurred_at` (ISO 8601). The response adds
  `resolved_height` (where it draws, nil when it can't be placed yet) and
  `resolved_by` (`txid`, `height`, `time` or `before_genesis`).
  """

  use BitblocksWeb, :controller

  alias Bitblocks.Annotations

  action_fallback BitblocksWeb.FallbackController

  def index(conn, params) do
    items =
      case {int(params["from"]), int(params["to"])} do
        {from, to} when is_integer(from) and is_integer(to) -> Annotations.list_between(from, to)
        _ -> Annotations.list()
      end

    items = if kind = params["kind"], do: Enum.filter(items, &(&1.kind == kind)), else: items
    json(conn, %{data: items, count: length(items), kinds: Annotations.kinds()})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, annotation} <- fetch(id), do: json(conn, %{data: annotation})
  end

  def create(conn, params) do
    with {:ok, annotation} <- Annotations.create(attrs(params)) do
      conn |> put_status(:created) |> json(%{data: annotation})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, annotation} <- fetch(id),
         {:ok, annotation} <- Annotations.update(annotation, attrs(params)) do
      json(conn, %{data: annotation})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, annotation} <- fetch(id),
         {:ok, _} <- Annotations.delete(annotation) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch(id) do
    case int(id) && Annotations.get(int(id)) do
      nil -> {:error, :not_found}
      annotation -> {:ok, annotation}
    end
  end

  defp attrs(%{"annotation" => attrs}) when is_map(attrs), do: attrs
  defp attrs(params), do: Map.drop(params, ["id"])

  defp int(nil), do: nil
  defp int(n) when is_integer(n), do: n

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
