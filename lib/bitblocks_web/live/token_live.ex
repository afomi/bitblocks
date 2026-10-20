defmodule BitblocksWeb.TokenLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.Tokens
  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Bitblocks.PubSub, "tokens")
    end

    {:ok, assign(socket, standard_filter: "", sym_filter: "")}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    # Detail view for a single token.
    token = Tokens.get_token(id)

    socket =
      if token do
        assign(
          socket,
          Seo.public_page(
            page_title: "Token #{token.sym || token.tick || token.token_id}",
            meta_description: "BSV-20 / BSV-21 token details, supply, and holders.",
            canonical_path: "/tokens/#{id}"
          )
        )
        |> assign(
          view: :detail,
          token: token,
          holders: Tokens.token_holders(id),
          transfers: Tokens.token_transfers(id, limit: 25)
        )
      else
        assign(socket, view: :not_found, token_id: id)
      end

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    # List view.
    socket =
      assign(
        socket,
        Seo.public_page(
          page_title: "Tokens",
          meta_description:
            "Browse BSV-20 and BSV-21 fungible tokens indexed from 1Sat Ordinal inscriptions.",
          canonical_path: "/tokens"
        )
      )
      |> assign(
        view: :list,
        tokens: Tokens.list_tokens(limit: 50),
        stats: Tokens.token_stats()
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    standard_filter = params["standard"] || ""
    sym_filter = params["sym"] || ""

    opts =
      [limit: 50]
      |> maybe_put(:standard, non_empty(standard_filter))
      |> maybe_put(:sym, non_empty(sym_filter))

    {:noreply,
     assign(socket,
       tokens: Tokens.list_tokens(opts),
       standard_filter: standard_filter,
       sym_filter: sym_filter
     )}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     assign(socket,
       tokens: Tokens.list_tokens(limit: 50),
       standard_filter: "",
       sym_filter: ""
     )}
  end

  @impl true
  def handle_info({:new_token, token}, socket) do
    # Only the list view tracks the live feed.
    if socket.assigns.view == :list do
      tokens = [token | socket.assigns.tokens]
      {:noreply, assign(socket, tokens: tokens, stats: Tokens.token_stats())}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- View helpers -----------------------------------------------------------

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp non_empty(""), do: nil
  defp non_empty(str), do: str

  def token_label(%{sym: sym}) when is_binary(sym) and sym != "", do: sym
  def token_label(%{tick: tick}) when is_binary(tick) and tick != "", do: tick
  def token_label(%{token_id: token_id}), do: token_id
  def token_label(_), do: "—"

  def standard_badge("bsv-21"), do: "bg-purple-100 text-purple-700"
  def standard_badge("bsv-20"), do: "bg-amber-100 text-amber-700"
  def standard_badge(_), do: "bg-gray-100 text-gray-700"

  def truncate(nil), do: ""

  def truncate(str) when byte_size(str) > 16 do
    String.slice(str, 0, 8) <> "..." <> String.slice(str, -6, 6)
  end

  def truncate(str), do: str

  def format_amount(nil), do: "—"

  def format_amount(amt) when is_binary(amt) do
    case Integer.parse(amt) do
      {n, _} -> delimit(n)
      :error -> amt
    end
  end

  def format_amount(amt) when is_integer(amt), do: delimit(amt)
  def format_amount(amt), do: to_string(amt)

  defp delimit(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
