defmodule BitblocksWeb.PricingLive.CloudQuote do
  @moduledoc """
  `/pricing#cloud` (https://github.com/afomi/bitblocks/issues/113): the three
  cloud services, and a quote request that helps a buyer describe a filter the
  way the projection API takes it, with a bounded estimate of what it would
  hold today (`Bitblocks.CloudQuote`).

  No price is set and nothing is billed: "Request a quote" opens an email to
  us with the spec and the estimate filled in. Typing updates the email; the
  estimate runs only on "Estimate", one at a time per page, as a capped count
  under a short statement timeout.
  """
  use BitblocksWeb, :live_component

  require Logger

  alias Bitblocks.CloudQuote
  alias Phoenix.LiveView.JS

  @impl true
  def mount(socket) do
    params = CloudQuote.default_params()

    {:ok,
     socket
     |> assign(:form, to_form(params, as: :cloud))
     |> assign(:spec, CloudQuote.parse(params))
     |> assign(:estimate, nil)
     |> assign(:estimate_error, nil)
     |> assign(:estimated_for, nil)
     |> assign(:estimating, false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, Map.take(assigns, [:id, :through, :contact_email]))}
  end

  @impl true
  def handle_event("change", %{"cloud" => params}, socket) do
    {:noreply, put_params(socket, params)}
  end

  def handle_event("estimate", %{"cloud" => params}, socket) do
    socket = put_params(socket, params)

    case {socket.assigns.spec, socket.assigns.estimating} do
      {{:ok, spec}, false} ->
        {:noreply,
         socket
         |> assign(:estimating, true)
         |> assign(:estimate_error, nil)
         |> start_async(:estimate, fn ->
           # Read now, so the estimate names the range it really counted.
           {spec, CloudQuote.estimate(spec, Bitblocks.Sync.complete_through())}
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("service", %{"service" => service}, socket) do
    params = Map.put(socket.assigns.form.params, "service", CloudQuote.service(service).id)
    {:noreply, put_params(socket, params)}
  end

  @impl true
  def handle_async(:estimate, {:ok, {spec, result}}, socket) do
    socket = assign(socket, :estimating, false)

    # A spec changed while it counted keeps no estimate for the old one.
    if spec_key(spec) == current_key(socket) do
      case result do
        {:ok, estimate} ->
          {:noreply,
           assign(socket, estimate: estimate, estimate_error: nil, estimated_for: spec_key(spec))}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             estimate: nil,
             estimate_error: CloudQuote.error_message(reason),
             estimated_for: spec_key(spec)
           )}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async(:estimate, {:exit, reason}, socket) do
    Logger.warning("Cloud quote estimate failed: #{inspect(reason)}")

    {:noreply,
     assign(socket,
       estimating: false,
       estimate: nil,
       estimate_error: CloudQuote.error_message(:unavailable)
     )}
  end

  # Keeps the form and its spec; an estimate made for another spec is dropped.
  defp put_params(socket, params) do
    spec = CloudQuote.parse(params)
    socket = assign(socket, form: to_form(params, as: :cloud), spec: spec)

    if current_key(socket) == socket.assigns.estimated_for,
      do: socket,
      else: assign(socket, estimate: nil, estimate_error: nil, estimated_for: nil)
  end

  defp current_key(%{assigns: %{spec: {:ok, spec}}}), do: spec_key(spec)
  defp current_key(_socket), do: :invalid

  defp spec_key(spec), do: Map.take(spec, [:source, :filter, :namespace, :from_height])

  @doc "The spec, when the form reads as one."
  def ok_spec({:ok, spec}), do: spec
  def ok_spec(_), do: nil

  @doc "Moves to the form with this service chosen, from a card's button."
  def choose(service, target) do
    JS.push("service", value: %{service: service}, target: target)
    |> JS.focus(to: "#cloud-service-#{service}")
  end

  defdelegate format_number(n), to: CloudQuote
end
