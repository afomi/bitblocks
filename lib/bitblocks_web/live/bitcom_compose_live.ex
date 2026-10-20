defmodule BitblocksWeb.BitcomComposeLive do
  @moduledoc """
  `/bitcom/compose`: builds the unsigned OP_RETURN for a Bitcom command and
  says which address must fund it. Bitblocks stays read-side; the wallet
  (qart) signs and broadcasts.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.Bitcom
  alias BitblocksWeb.Seo

  @commands [
    {"useradd", "$ useradd — claim the funding address as a protocol prefix"},
    {"echo", "$ echo … to — write a file"},
    {"cat", "$ cat bit://… to — point a file at another tx"},
    {"route enable", "$ route enable — open a route (admin)"},
    {"route add", "$ route add — serve someone's route (provider)"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        Seo.public_page(
          page_title: "Compose a Bitcom command",
          meta_description:
            "Build the OP_RETURN for a Bitcom command (useradd, echo, cat, route) to sign in your wallet.",
          canonical_path: "/bitcom/compose"
        )
      )
      |> assign(commands: @commands)
      |> compose(%{"command" => "useradd"})

    {:ok, socket}
  end

  @impl true
  def handle_event("compose", %{"compose" => params}, socket),
    do: {:noreply, compose(socket, params)}

  defp compose(socket, params) do
    funder = String.trim(params["funder"] || "")

    result = if funder != "", do: Bitcom.compose(pushes(params, funder), funder)

    assign(socket,
      form: to_form(params, as: :compose),
      command: params["command"] || "useradd",
      result: result
    )
  end

  defp pushes(%{"command" => "useradd"}, funder), do: ["useradd", funder]
  defp pushes(%{"command" => "echo"} = p, _), do: ["echo", p["content"] || "", "to", file(p)]
  defp pushes(%{"command" => "cat"} = p, _), do: ["cat", trim(p["locator"]), "to", file(p)]
  defp pushes(%{"command" => "route enable"} = p, _), do: ["route", "enable", trim(p["matcher"])]

  defp pushes(%{"command" => "route add"} = p, _),
    do: ["route", "add", trim(p["admin"]), trim(p["matcher"]), trim(p["endpoint"])]

  defp pushes(_params, _funder), do: []

  defp file(params), do: trim(params["file"])
  defp trim(nil), do: ""
  defp trim(value), do: String.trim(value)
end
