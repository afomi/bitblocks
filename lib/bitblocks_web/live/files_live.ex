defmodule BitblocksWeb.FilesLive do
  @moduledoc """
  `/files`: the B:// files in the stored chain, newest stored first, each
  with its name, type, size and C:// address (`Bitblocks.Bitcom.Files`).
  unwriter's C.TXT, "find files on Bitcoin", revived (#25). Files open at
  `/b/:txid`, under that route's untrusted-content headers; nothing is shown
  inline.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.Bitcom.Files
  alias BitblocksWeb.Seo

  import BitblocksWeb.Sats, only: [delimit: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(
       socket,
       Seo.public_page(
         page_title: "Files on Bitcoin",
         meta_description:
           "B:// files stored on Bitcoin SV, newest first, with each file's name, type, size and C:// content address.",
         canonical_path: "/files"
       )
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    before =
      case Integer.parse(params["before"] || "") do
        {id, ""} when id > 0 -> id
        _ -> nil
      end

    socket = assign(socket, first_page: is_nil(before))

    case Files.list(before: before) do
      {:ok, page} -> {:noreply, assign(socket, files: page.files, next: page.before, error: nil)}
      {:error, reason} -> {:noreply, assign(socket, files: [], next: nil, error: reason)}
    end
  end

  @doc "The first and last eight hex characters, for a hash in a narrow column."
  def short(hex), do: String.slice(hex, 0, 8) <> "…" <> String.slice(hex, -8, 8)
end
