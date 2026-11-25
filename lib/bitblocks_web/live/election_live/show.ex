defmodule BitblocksWeb.ElectionLive.Show do
  @moduledoc """
  `/elections/:outpoint`: the live count of one election.

  Loaded with `Elections.gather/2` and `Elections.count/1`.
  A gather or count error is a sentence on the page, never a 500.
  Bitblocks does not sign or send a ballot.

  Admins also get "Build the archive" (`BitblocksWeb.ElectionArchive`),
  disabled with `Archive.plan/2`'s refusal until the close is deep enough.
  """
  use BitblocksWeb, :live_view

  alias BitblocksWeb.{ElectionArchive, ElectionCount}
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
     |> assign(:lookup_error, nil)
     |> assign(:archive, archive(socket, outpoint))}
  end

  # "Build the archive" (#136, step 5), admins only. Whether it can be built
  # is Archive.plan/2's answer (`ElectionArchive.readiness/1`).
  defp archive(%{assigns: %{admin?: true, count: count}}, outpoint) when is_map(count) do
    {status, reason} =
      case ElectionArchive.readiness(outpoint) do
        :ready -> {:ready, nil}
        {:refused, sentence} -> {:refused, sentence}
      end

    %{status: status, reason: reason, built: nil, error: nil, result_txid: ""}
  end

  defp archive(_socket, _outpoint), do: nil

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

  def handle_event(
        "build_archive",
        params,
        %{assigns: %{admin?: true, archive: %{status: :ready} = archive, count: count}} = socket
      ) do
    result_txid = String.trim(params["result_txid"] || "")
    opts = if result_txid == "", do: [], else: [result_txid: result_txid]

    archive =
      case ElectionArchive.build(count.election, opts) do
        {:ok, built} -> %{archive | built: built, error: nil, result_txid: result_txid}
        {:error, sentence} -> %{archive | built: nil, error: sentence, result_txid: result_txid}
      end

    {:noreply, assign(socket, :archive, archive)}
  end

  def handle_event("build_archive", _params, socket), do: {:noreply, socket}

  @doc "The download link's query: the archive_sha256 shown, and the result txid if given."
  @spec download_query(map()) :: keyword()
  def download_query(%{archive_sha256: sha256, result_txid: nil}), do: [sha256: sha256]

  def download_query(%{archive_sha256: sha256, result_txid: txid}),
    do: [sha256: sha256, result_txid: txid]

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
