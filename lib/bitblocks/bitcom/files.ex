defmodule Bitblocks.Bitcom.Files do
  @moduledoc """
  The B:// files in the stored chain, newest stored first: what `/files`
  lists (unwriter's C.TXT, "find files on Bitcoin", #25).

  A page is the txs tagged `B://` at ingest, newest id first, and each file
  is parsed from its tx's bytes (`Bitcom.BFile`) as the page is read; nothing
  is extracted ahead of time. A file's C:// address is the sha256 of its
  content, the key unwriter's C:// names a file by.

  The tag is read through its GIN index: ordering by `id + 0` keeps the
  planner off a backward walk of the primary key, which on prod meets
  millions of newer untagged rows (the genesis-era blocks are stored last)
  before it fills a page. That read has a 5 s statement timeout and says so
  when it runs out, rather than holding a connection.
  """

  import Ecto.Query

  alias Bitblocks.Bitcom.BFile
  alias Bitblocks.Chain.{RawTx, Transaction}
  alias Bitblocks.{ChainScrubber, Repo, TxStore}

  @tag "B://"
  @per_page 25
  @timeout_ms 5_000

  @type file :: %{
          txid: String.t(),
          block_height: integer() | nil,
          parsed: boolean(),
          filename: String.t() | nil,
          media_type: String.t() | nil,
          encoding: String.t() | nil,
          size: non_neg_integer() | nil,
          sha256: String.t() | nil
        }

  @doc """
  A page of files, newest stored first: `{:ok, %{files:, before:}}`.
  `opts[:before]` is the `before` of the previous page; `opts[:per_page]`
  defaults to #{@per_page}. `before` in the answer is nil on the last page.

  A tx tagged `B://` whose bytes we can't read, or that holds no B:// file
  of its own (the prefix appears later in a script), is listed with
  `parsed: false` rather than dropped, so the list stays the tag's.
  `{:error, :timeout}` when the read ran out of time.
  """
  @spec list(keyword()) ::
          {:ok, %{files: [file()], before: pos_integer() | nil}}
          | {:error, :timeout | :unavailable}
  def list(opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @per_page)

    ids =
      from(t in Transaction,
        where: fragment("? @> ARRAY[?]::varchar[]", t.protocols, ^@tag),
        order_by: [desc: fragment("? + 0", t.id)],
        limit: ^(per_page + 1),
        select: t.id
      )
      |> before(opts[:before])

    case ChainScrubber.with_statement_timeout(@timeout_ms, fn -> Repo.all(ids) end) do
      {:ok, ids} -> {:ok, page(ids, per_page)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp page(ids, per_page) do
    {ids, more} = Enum.split(ids, per_page)

    rows =
      from(t in Transaction,
        where: t.id in ^ids,
        order_by: [desc: t.id],
        select: %{id: t.id, txid: t.txid, block_height: t.block_height, raw: t.raw}
      )
      |> Repo.all()

    files =
      rows
      |> Task.async_stream(&file/1, max_concurrency: 8, timeout: 10_000, on_timeout: :kill_task)
      |> Enum.zip(rows)
      |> Enum.map(fn
        {{:ok, file}, _row} -> file
        {{:exit, _}, row} -> unparsed(row)
      end)

    %{files: files, before: if(more != [], do: List.last(ids))}
  end

  # `id + 0`, like the order, so the primary key stays out of the plan.
  defp before(query, id) when is_integer(id),
    do: from(t in query, where: fragment("? + 0 < ?", t.id, ^id))

  defp before(query, _id), do: query

  @doc "One tx's B:// file as `list/1` gives it."
  @spec file(%{txid: String.t(), block_height: integer() | nil, raw: String.t() | nil}) :: file()
  def file(row) do
    with %{raw: hex} when is_binary(hex) and hex != "" <- TxStore.with_raw(row),
         {:ok, tx} <- RawTx.parse(hex),
         {:ok, b} <- BFile.parse(tx) do
      %{
        txid: row.txid,
        block_height: row.block_height,
        parsed: true,
        filename: b.filename,
        media_type: b.media_type,
        encoding: b.encoding,
        size: byte_size(b.content),
        sha256: :crypto.hash(:sha256, b.content) |> Base.encode16(case: :lower)
      }
    else
      _ -> unparsed(row)
    end
  end

  defp unparsed(row) do
    %{
      txid: row.txid,
      block_height: row.block_height,
      parsed: false,
      filename: nil,
      media_type: nil,
      encoding: nil,
      size: nil,
      sha256: nil
    }
  end
end
