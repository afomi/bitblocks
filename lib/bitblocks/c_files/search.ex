defmodule Bitblocks.CFiles.Search do
  @moduledoc """
  Find a file in the C:// index (https://github.com/afomi/bitblocks/issues/175):
  unwriter's C.TXT, "find files on Bitcoin", over the `c_files` table
  (`Bitblocks.CFiles`), B:// and BCat files alike.

  A search reads `c_files` only, never `transactions`. The table is small
  (B:// and BCat txs are rare), so a bounded `ILIKE` on the filename and a
  test on the media type, under `LIMIT` and a #{2_000} ms statement timeout,
  need no index of their own.

    * `q`: part of a filename, matched case-insensitively; `%` and `_`
      match themselves. At most #{100} characters are used. A 64-hex `q` is
      a C:// address instead, and matches that file's sha256 exactly.
    * `type`: one of `types/0`, read from the media type before any `;`.
    * `cursor`: `<height>:<id>`, the `next_cursor` of the page before.

  Results are newest block first (a file whose block is unknown last), then
  newest row first, so a page picks up from the last result and never
  repeats one.

  An empty result is only a miss in our index: `coverage/0` says how far it
  reaches, and the page and the API say so.
  """

  import Ecto.Query

  alias Bitblocks.{ChainScrubber, CFiles, Repo}
  alias Bitblocks.CFiles.CFile

  @per_page 25
  @max_per_page 100
  @max_query 100
  @timeout_ms 2_000
  @types ~w(image text json html other)

  @type opts :: [q: String.t() | nil, type: String.t() | nil, cursor: String.t() | nil]
  @type page :: %{files: [CFile.t()], next_cursor: String.t() | nil}

  @doc "The type filters: #{Enum.join(@types, ", ")}."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The most characters of `q` a search uses."
  @spec max_query() :: pos_integer()
  def max_query, do: @max_query

  @doc """
  `q` as a search reads it: trimmed and cut to #{@max_query} characters;
  nil when blank.
  """
  @spec normalize_query(term()) :: String.t() | nil
  def normalize_query(q) when is_binary(q) do
    case q |> String.trim() |> String.slice(0, @max_query) do
      "" -> nil
      q -> q
    end
  end

  def normalize_query(_q), do: nil

  @doc """
  What `q` asks for: `{:address, sha256}` (32 raw bytes) for a 64-hex C://
  address, with or without `c://`; `{:name, q}` otherwise; nil when blank.
  """
  @spec classify(term()) :: {:address, binary()} | {:name, String.t()} | nil
  def classify(q) do
    case normalize_query(q) do
      nil ->
        nil

      q ->
        hex = String.replace_prefix(q, "c://", "")

        case CFiles.parse_address(hex) do
          {:ok, sha256} -> {:address, sha256}
          :error -> {:name, q}
        end
    end
  end

  @doc "`{:ok, cursor}` for `<height>:<id>`, `{:ok, nil}` when blank, else `:error`."
  @spec parse_cursor(term()) :: {:ok, {integer(), pos_integer()} | nil} | :error
  def parse_cursor(nil), do: {:ok, nil}
  def parse_cursor(""), do: {:ok, nil}

  def parse_cursor(cursor) when is_binary(cursor) do
    with [h, id] <- String.split(cursor, ":"),
         {h, ""} when h >= -1 <- Integer.parse(h),
         {id, ""} when id > 0 <- Integer.parse(id) do
      {:ok, {h, id}}
    else
      _ -> :error
    end
  end

  def parse_cursor(_cursor), do: :error

  @doc """
  One page of matching files: `{:ok, %{files:, next_cursor:}}`.
  `next_cursor` is nil on the last page. `{:error, :invalid_type}` or
  `{:error, :invalid_cursor}` for an option it can't read, and
  `{:error, :timeout}` or `{:error, :unavailable}` when the read didn't
  finish.

  Options: `q`, `type`, `cursor` (see the moduledoc) and `per_page`
  (default #{@per_page}, at most #{@max_per_page}).
  """
  @spec search(keyword()) ::
          {:ok, page()}
          | {:error, :invalid_type | :invalid_cursor | :timeout | :unavailable}
  def search(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, @per_page) |> min(@max_per_page) |> max(1)

    with {:ok, query} <- query(opts),
         {:ok, rows} <-
           ChainScrubber.with_statement_timeout(@timeout_ms, fn ->
             Repo.all(from(c in query, limit: ^(per_page + 1)))
           end) do
      {files, more} = Enum.split(rows, per_page)
      {:ok, %{files: files, next_cursor: if(more != [], do: cursor(List.last(files)))}}
    end
  end

  @doc """
  The search as a query, unlimited: what `search/1` runs under `LIMIT`, and
  what the tests `EXPLAIN`.
  """
  @spec query(keyword()) :: {:ok, Ecto.Query.t()} | {:error, :invalid_type | :invalid_cursor}
  def query(opts) do
    type = blank_to_nil(opts[:type])

    cond do
      type && type not in @types ->
        {:error, :invalid_type}

      parse_cursor(opts[:cursor]) == :error ->
        {:error, :invalid_cursor}

      true ->
        {:ok, cursor} = parse_cursor(opts[:cursor])

        query =
          from(c in CFile,
            order_by: [desc: fragment("coalesce(?, -1)", c.block_height), desc: c.id]
          )
          |> match(classify(opts[:q]))
          |> of_type(type)
          |> after_cursor(cursor)

        {:ok, query}
    end
  end

  @doc "The cursor that picks up after this row."
  @spec cursor(CFile.t()) :: String.t()
  def cursor(%CFile{block_height: h, id: id}), do: "#{h || -1}:#{id}"

  @doc """
  How far a search reaches: `CFiles.coverage/0` plus
  `earliest_indexed_height`, the lowest block a file in the index was mined
  in (nil when the index is empty). Until a backfill covers block 0, the
  index holds the files in blocks synced since the step shipped, so this is
  roughly where it starts.
  """
  @spec coverage() :: map()
  def coverage do
    earliest =
      ChainScrubber.with_statement_timeout(@timeout_ms, fn ->
        Repo.one(from(c in CFile, select: min(c.block_height)))
      end)

    Map.put(
      CFiles.coverage(),
      :earliest_indexed_height,
      case earliest do
        {:ok, h} -> h
        {:error, _} -> nil
      end
    )
  end

  defp match(query, nil), do: query

  defp match(query, {:address, sha256}), do: from(c in query, where: c.sha256 == ^sha256)

  defp match(query, {:name, q}) do
    pattern = "%" <> escape_like(q) <> "%"
    from(c in query, where: ilike(c.filename, ^pattern))
  end

  # LIKE's escape character is a backslash, so `%`, `_` and `\` are matched
  # as themselves.
  defp escape_like(q), do: String.replace(q, ["\\", "%", "_"], &("\\" <> &1))

  # The media type before any parameters, lower case: "Image/PNG; x=y" is
  # "image/png".
  defmacrop media(c) do
    quote do
      fragment("lower(btrim(split_part(coalesce(?, ''), ';', 1)))", unquote(c).media_type)
    end
  end

  defp of_type(query, nil), do: query
  defp of_type(query, "image"), do: from(c in query, where: like(media(c), "image/%"))
  defp of_type(query, "html"), do: from(c in query, where: media(c) == "text/html")

  defp of_type(query, "json"),
    do: from(c in query, where: media(c) == "application/json" or like(media(c), "%+json"))

  defp of_type(query, "text"),
    do: from(c in query, where: like(media(c), "text/%") and media(c) != "text/html")

  defp of_type(query, "other") do
    from(c in query,
      where:
        not like(media(c), "image/%") and not like(media(c), "text/%") and
          media(c) != "application/json" and not like(media(c), "%+json")
    )
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {h, id}) do
    from(c in query,
      where: fragment("(coalesce(?, -1), ?) < (?, ?)", c.block_height, c.id, ^h, ^id)
    )
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v
end
