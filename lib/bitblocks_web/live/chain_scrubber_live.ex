defmodule BitblocksWeb.ChainScrubberLive do
  @moduledoc """
  Admin exploration (#48): scrub the chain from genesis to tip.

  The scene is the `ChainScrubber` hook, fed by precomputed tiles. This
  LiveView owns the parts that need the server: the build status, the typed
  height jump, the capped tx read when the scrubber rests
  (`Bitblocks.ChainScrubber.rest/2`), and the annotation layer.
  """

  use BitblocksWeb, :live_view

  alias Bitblocks.ChainScrubber
  alias Bitblocks.ChainTiles
  alias Bitblocks.ChainTiles.Cache

  @impl true
  def mount(params, _session, socket) do
    manifest = Cache.manifest()
    tip = (manifest && manifest.tip_height) || ChainTiles.chain_tip() || 0
    {view_from, view_to} = parse_view(params, tip)
    height = params |> Map.get("height") |> parse_height(tip) || view_from
    annotations = ChainScrubber.annotations()

    socket =
      assign(socket,
        page_title: "Chain scrubber",
        tip_height: tip,
        height: height,
        view_from: view_from,
        view_to: view_to,
        built?: manifest != nil,
        built_at: manifest && DateTime.from_unix!(manifest.built_at),
        last_build: ChainTiles.last_build(),
        annotations: annotations,
        rest: nil,
        jump_error: nil
      )

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Bitblocks.PubSub, Bitblocks.Annotations.topic())
        push_event(socket, "annotations", %{items: annotations})
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("jump", %{"height" => text}, socket) do
    case parse_height(text, socket.assigns.tip_height) do
      nil ->
        {:noreply,
         assign(socket,
           jump_error: "Enter a height between 0 and #{socket.assigns.tip_height}."
         )}

      height ->
        {:noreply,
         socket
         |> assign(height: height, jump_error: nil)
         |> push_event("jump", %{height: height})}
    end
  end

  def handle_event("rest", %{"height" => height}, socket) do
    case parse_height(height, socket.assigns.tip_height) do
      nil ->
        {:noreply, socket}

      height ->
        payload = ChainScrubber.rest(height)

        {:noreply,
         socket
         |> assign(height: height, rest: payload)
         |> push_event("rest_data", payload)}
    end
  end

  # An admin added, changed or removed a chain annotation: redraw the markers.
  @impl true
  def handle_info(:annotations_changed, socket) do
    annotations = ChainScrubber.annotations()

    {:noreply,
     socket
     |> assign(annotations: annotations)
     |> push_event("annotations", %{items: annotations})}
  end

  @doc """
  The opening view from `?from=&to=` (both heights in `0..tip`, `from < to`),
  so a stretch such as the first 200,000 blocks can be studied on its own.
  Anything else opens the whole chain.
  """
  @spec parse_view(map(), non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def parse_view(params, tip) do
    with from when is_integer(from) <- parse_height(params["from"], tip),
         to when is_integer(to) and to > from <- parse_height(params["to"], tip) do
      {from, to}
    else
      _ -> {0, tip}
    end
  end

  @doc "A typed or pushed height as an integer in `0..tip`, or nil."
  @spec parse_height(term(), non_neg_integer()) :: non_neg_integer() | nil
  def parse_height(height, tip) when is_integer(height) and height >= 0 and height <= tip,
    do: height

  def parse_height(text, tip) when is_binary(text) do
    cleaned = text |> String.trim() |> String.replace(~r/[,_\s]/, "")

    case Integer.parse(cleaned) do
      {height, ""} -> parse_height(height, tip)
      _ -> nil
    end
  end

  def parse_height(_, _tip), do: nil
end
