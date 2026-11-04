defmodule BitblocksWeb.AnnotationLive do
  @moduledoc """
  Admin CRUD for chain annotations (`Bitblocks.Annotations`): forks,
  upgrades, halvings, mintings, milestones and real-world events, each placed
  on the chain by a height, a txid or a date. The same records are at
  `/api/v1/annotations` and draw on `/chain-scrubber` and `/tx-graph`.
  """

  use BitblocksWeb, :live_view

  alias Bitblocks.Annotations
  alias Bitblocks.Annotations.Annotation

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Bitblocks.PubSub, Annotations.topic())

    {:ok,
     socket
     |> assign(page_title: "Chain annotations", kind_filter: "", notice: nil)
     |> load()
     |> edit(%Annotation{})}
  end

  @impl true
  def handle_event("validate", %{"annotation" => params}, socket) do
    changeset =
      socket.assigns.editing
      |> Annotations.change(form_attrs(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset), when_text: params["when"])}
  end

  def handle_event("save", %{"annotation" => params}, socket) do
    attrs = form_attrs(params)

    result =
      case socket.assigns.editing do
        %Annotation{id: nil} -> Annotations.create(attrs)
        annotation -> Annotations.update(annotation, attrs)
      end

    case result do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(notice: placed_notice(saved))
         |> load()
         |> edit(%Annotation{})}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset), when_text: params["when"])}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Annotations.get(String.to_integer(id)) do
      nil -> {:noreply, socket}
      annotation -> {:noreply, socket |> assign(notice: nil) |> edit(annotation)}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(notice: nil) |> edit(%Annotation{})}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %Annotation{} = annotation <- Annotations.get(String.to_integer(id)),
         {:ok, _} <- Annotations.delete(annotation) do
      {:noreply,
       socket
       |> assign(notice: "Deleted \"#{annotation.title}\".")
       |> load()
       |> edit(%Annotation{})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("filter", %{"kind" => kind}, socket) do
    {:noreply, socket |> assign(kind_filter: kind) |> load()}
  end

  def handle_event("seed", _params, socket) do
    {added, skipped} = Annotations.seed()

    {:noreply,
     socket
     |> assign(notice: "Added #{added} curated events; #{skipped} were already here.")
     |> load()}
  end

  def handle_event("resolve_all", _params, socket) do
    placed = Annotations.resolve_all()
    {:noreply, socket |> assign(notice: "Placed #{placed} more on the chain.") |> load()}
  end

  @impl true
  def handle_info(:annotations_changed, socket), do: {:noreply, load(socket)}

  # -- helpers -------------------------------------------------------------

  defp load(socket) do
    all = Annotations.list()

    items =
      case socket.assigns.kind_filter do
        "" -> all
        kind -> Enum.filter(all, &(&1.kind == kind))
      end

    assign(socket,
      items: items,
      total: length(all),
      unplaced: Enum.count(all, &is_nil(&1.resolved_height))
    )
  end

  defp edit(socket, %Annotation{} = annotation) do
    assign(socket,
      editing: annotation,
      form: to_form(Annotations.change(annotation)),
      when_text: when_text(annotation.occurred_at)
    )
  end

  # The form's one date field takes a day (2010-05-22) or a full ISO 8601
  # time (2009-01-03T18:15:05Z); a day means midnight UTC.
  defp form_attrs(params) do
    occurred_at =
      case String.trim(params["when"] || "") do
        "" -> nil
        <<_::binary-size(10)>> = day -> day <> "T00:00:00Z"
        text -> text
      end

    params
    |> Map.delete("when")
    |> Map.put("occurred_at", occurred_at)
  end

  defp when_text(nil), do: ""

  defp when_text(%DateTime{hour: 0, minute: 0, second: 0} = at),
    do: at |> DateTime.to_date() |> Date.to_iso8601()

  defp when_text(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp placed_notice(%Annotation{resolved_height: nil, resolved_by: "before_genesis"} = a),
    do: "Saved \"#{a.title}\". It is before the genesis block, so it stays off the chain."

  defp placed_notice(%Annotation{resolved_height: nil} = a),
    do: "Saved \"#{a.title}\". It isn't on the chain we hold yet; \"Place again\" retries."

  defp placed_notice(%Annotation{} = a),
    do: "Saved \"#{a.title}\" at block #{a.resolved_height} (by #{a.resolved_by})."

  @doc false
  def kind_class("fork"),
    do: "bg-violet-100 text-violet-900 dark:bg-violet-900/40 dark:text-violet-200"

  def kind_class("upgrade"), do: "bg-sky-100 text-sky-900 dark:bg-sky-900/40 dark:text-sky-200"

  def kind_class("halving"),
    do: "bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-200"

  def kind_class("milestone"),
    do: "bg-emerald-100 text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200"

  def kind_class("mint"), do: "bg-pink-100 text-pink-900 dark:bg-pink-900/40 dark:text-pink-200"
  def kind_class("world"), do: "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200"
  def kind_class(_), do: "bg-blue-100 text-blue-900 dark:bg-blue-900/40 dark:text-blue-200"

  @doc false
  def placed_text(%Annotation{resolved_height: h}) when is_integer(h), do: Integer.to_string(h)
  def placed_text(%Annotation{resolved_by: "before_genesis"}), do: "before genesis"
  def placed_text(_), do: "not yet"
end
