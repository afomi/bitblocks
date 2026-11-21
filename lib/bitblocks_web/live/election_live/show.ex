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

    {:ok, assign(socket, :lookup, "")}
  end

  @impl true
  def handle_event("lookup", params, socket) do
    {:noreply, assign(socket, :lookup, String.trim(params["query"] || ""))}
  end

  @doc "Ballots whose signer or txid equals `lookup`, or every ballot when it is blank."
  @spec shown_ballots([map()], String.t()) :: [map()]
  def shown_ballots(ballots, lookup) do
    query = String.trim(lookup || "")

    if query == "" do
      ballots
    else
      Enum.filter(ballots, &ballot_matches?(&1, query))
    end
  end

  defp ballot_matches?(%{signer: signer, txid: txid}, query) do
    query == signer or query == txid or String.downcase(query) == txid
  end

  defp seo(title, outpoint) do
    Seo.public_page(
      page_title: title,
      meta_description:
        "The live count of an election on Bitcoin SV. Bitblocks reads the chain and does not cast a vote.",
      canonical_path: "/elections/#{outpoint}"
    )
  end
end
