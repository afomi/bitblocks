defmodule Bitblocks.Bitcom.Files do
  @moduledoc """
  The B:// files in the stored chain, newest stored first: what `/files`
  lists (unwriter's C.TXT, "find files on Bitcoin", #25).

  A page is the txs tagged `B://` at ingest, read by id on the primary key,
  and each file is parsed from its tx's bytes (`Bitcom.BFile`) as the page is
  read; nothing is extracted ahead of time. A file's C:// address is the
  sha256 of its content, the key unwriter's C:// names a file by.
  """

  import Ecto.Query

  alias Bitblocks.Bitcom.BFile
  alias Bitblocks.Chain.{RawTx, Transaction}
  alias Bitblocks.{Repo, TxStore}

  @tag "B://"
  @per_page 25

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
  A page of files, newest stored first. `opts[:before]` is the `before` of
  the previous page; `opts[:per_page]` defaults to #{@per_page}. `before` in
  the answer is nil on the last page.

  A tx tagged `B://` whose bytes we can't read, or that holds no B:// file
  of its own (the prefix appears later in a script), is listed with
  `parsed: false` rather than dropped, so the list stays the tag's.
  """
  @spec list(keyword()) :: %{files: [file()], before: pos_integer() | nil}
  def list(opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @per_page)

    rows =
      from(t in Transaction,
        where: fragment("? @> ARRAY[?]::varchar[]", t.protocols, ^@tag),
        order_by: [desc: t.id],
        limit: ^(per_page + 1),
        select: %{id: t.id, txid: t.txid, block_height: t.block_height, raw: t.raw}
      )
      |> before(opts[:before])
      |> Repo.all()

    {page, more} = Enum.split(rows, per_page)

    files =
      page
      |> Task.async_stream(&file/1, max_concurrency: 8, timeout: 10_000, on_timeout: :kill_task)
      |> Enum.zip(page)
      |> Enum.map(fn
        {{:ok, file}, _row} -> file
        {{:exit, _}, row} -> unparsed(row)
      end)

    %{files: files, before: if(more != [], do: List.last(page).id)}
  end

  defp before(query, id) when is_integer(id), do: from(t in query, where: t.id < ^id)
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
