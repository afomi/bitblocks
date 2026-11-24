defmodule BitblocksWeb.ElectionLive.Show do
  @moduledoc """
  `/elections/:outpoint`: the live count of one election.

  Loaded with `Elections.gather/2` and `Elections.count/1`.
  A gather or count error is a sentence on the page, never a 500.
  Bitblocks does not sign or send a ballot.
  """
  use BitblocksWeb, :live_view

  alias BitblocksWeb.ElectionCount
  alias BitblocksWeb.Seo

  @impl true
  def mount(%{"outpoint" => outpoint}, _session, socket) do
    socket =
      case ElectionCount.load(outpoint) do
        {:ok, count} ->
          socket
          |> assign(seo(count.name, outpoint))
          |> assign(:count, count)
          |> assign(:error, nil)

        {:error, _status, message} ->
          socket
          |> assign(seo("Election", outpoint))
          |> assign(:count, nil)
          |> assign(:error, message)
      end

    {:ok,
     socket
     |> assign(:lookup, "")
     |> assign(:answer, nil)
     |> assign(:lookup_error, nil)}
  end

  # The member's answer, read from the count already on the page
  # (`ElectionCount.lookup/2`), never a second rule.
  @impl true
  def handle_event("lookup", params, %{assigns: %{count: count}} = socket)
      when is_map(count) do
    query = String.trim(params["query"] || "")

    socket =
      case ElectionCount.lookup(count, query) do
        {:ok, answer} ->
          assign(socket, answer: answer, lookup_error: nil)

        {:error, :blank} ->
          assign(socket, answer: nil, lookup_error: nil)

        {:error, reason} ->
          assign(socket, answer: nil, lookup_error: ElectionCount.lookup_message(reason))
      end

    {:noreply, assign(socket, :lookup, query)}
  end

  def handle_event("lookup", _params, socket), do: {:noreply, socket}

  @doc "The ballots an answer names: the one for a txid, or an address's in chain order."
  @spec answer_ballots(map()) :: [map()]
  def answer_ballots(%{kind: :txid, ballot: ballot}), do: [ballot]
  def answer_ballots(%{kind: :address, ballots: ballots}), do: ballots

  defp seo(title, outpoint) do
    Seo.public_page(
      page_title: title,
      meta_description:
        "The live count of an election on Bitcoin SV. Bitblocks reads the chain and does not cast a vote.",
      canonical_path: "/elections/#{outpoint}"
    )
  end
end
