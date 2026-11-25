defmodule BitblocksWeb.FilesLive do
  @moduledoc """
  `/files`: the B:// files in the stored chain, newest stored first, each
  with its name, type, size and C:// address (`Bitblocks.Bitcom.Files`).
  unwriter's C.TXT, "find files on Bitcoin", revived (#25). Files open at
  `/b/:txid`, under that route's untrusted-content headers; nothing is shown
  inline.

  With `?q=` or `?type=` it searches the C:// index instead
  (`Bitblocks.CFiles.Search`, #175): B:// and BCat files by name, type or
  C:// address, paged by `?cursor=`, saying how far the index reaches. A
  64-hex `q` the index holds goes straight to `/c/:sha256`.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.Bitcom.Files
  alias Bitblocks.CFiles
  alias Bitblocks.CFiles.Search
  alias BitblocksWeb.Seo

  import BitblocksWeb.Sats, only: [delimit: 1]

  @type_options [
    {"Any type", ""},
    {"Images", "image"},
    {"Text", "text"},
    {"JSON", "json"},
    {"HTML", "html"},
    {"Other", "other"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(
       socket,
       Seo.public_page(
         page_title: "Files on Bitcoin",
         meta_description:
           "B:// files stored on Bitcoin SV, newest first, with each file's name, type, size and C:// content address. Search them by name, type or C:// address.",
         canonical_path: "/files"
       )
       |> Map.put(:type_options, @type_options)
       |> Map.put(:max_query, Search.max_query())
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = Search.normalize_query(params["q"])
    type = if params["type"] in Search.types(), do: params["type"]

    socket = assign(socket, q: q, type: type)

    if q || type,
      do: search(socket, q, type, params["cursor"]),
      else: list(socket, params)
  end

  @impl true
  def handle_event("search", params, socket) do
    query =
      [q: Search.normalize_query(params["q"]), type: blank_to_nil(params["type"])]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    {:noreply, push_patch(socket, to: ~p"/files?#{query}")}
  end

  defp list(socket, params) do
    before =
      case Integer.parse(params["before"] || "") do
        {id, ""} when id > 0 -> id
        _ -> nil
      end

    socket = assign(socket, mode: :list, first_page: is_nil(before))

    case Files.list(before: before) do
      {:ok, page} -> {:noreply, assign(socket, files: page.files, next: page.before, error: nil)}
      {:error, reason} -> {:noreply, assign(socket, files: [], next: nil, error: reason)}
    end
  end

  defp search(socket, q, type, cursor) do
    case Search.classify(q) do
      {:address, sha256} when is_nil(type) ->
        address(socket, sha256)

      _ ->
        # A garbled cursor on the page is the first page, never an error.
        cursor = if Search.parse_cursor(cursor) == :error, do: nil, else: cursor
        run_search(socket, q, type, cursor)
    end
  end

  defp address(socket, sha256) do
    hex = Base.encode16(sha256, case: :lower)

    if CFiles.locations(sha256) == [] do
      {:noreply,
       assign(socket,
         mode: :search,
         address: hex,
         results: [],
         next_cursor: nil,
         first_page: true,
         search_error: nil,
         coverage: Search.coverage()
       )}
    else
      {:noreply, redirect(socket, to: ~p"/c/#{hex}")}
    end
  end

  defp run_search(socket, q, type, cursor) do
    socket =
      assign(socket,
        mode: :search,
        address: nil,
        first_page: cursor in [nil, ""],
        coverage: Search.coverage()
      )

    case Search.search(q: q, type: type, cursor: cursor) do
      {:ok, page} ->
        {:noreply,
         assign(socket, results: page.files, next_cursor: page.next_cursor, search_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, results: [], next_cursor: nil, search_error: reason)}
    end
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  @doc "The first and last eight hex characters, for a hash in a narrow column."
  def short(hex), do: String.slice(hex, 0, 8) <> "…" <> String.slice(hex, -8, 8)

  @doc "The lowercase hex of a raw sha256."
  def hex(sha256), do: Base.encode16(sha256, case: :lower)

  @doc "Where a search result opens by its transaction."
  def open_path(%{kind: "bcat", txid: txid}), do: ~p"/content/bcat/#{txid}"
  def open_path(%{txid: txid}), do: ~p"/b/#{txid}"

  @doc "The query string for the next page of a search."
  def next_query(q, type, cursor) do
    [q: q, type: type, cursor: cursor] |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc "A type filter's label, for the sentence that says what was searched."
  def type_label(type) do
    Enum.find_value(@type_options, "any type", fn {label, value} ->
      if value == type, do: String.downcase(label)
    end)
  end
end
