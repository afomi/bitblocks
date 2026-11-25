defmodule Bitblocks.Elections.ArchivePage do
  @moduledoc """
  `index.html` in an election archive (`docs/ELECTION_DOGFOOD.md`, "The
  archive page", https://github.com/afomi/bitblocks/issues/138): the election's
  name, the tally, the winners, `archive_sha256`, the result record's txid
  once it exists, and "Recount it yourself", linking the copies of
  `recount.py` and `recount.html` beside it.

  Made from the archive's own `count.json` bytes, so the page and the
  archive say the same count. Self-contained HTML and CSS: no script, no font,
  image or stylesheet to fetch, so it opens from a file or any static host.
  It reads no clock, so the same archive gives the same page.

  It sits beside `MANIFEST.sha256`, not in it: it shows `archive_sha256`,
  which is taken over the manifest.
  """

  require EEx

  @template Path.join(__DIR__, "archive_page.html.eex")
  @external_resource @template

  @doc """
  The page for an archive whose `count.json` is `count_json` (its exact
  bytes) and whose manifest hashes to `archive_sha256`. `result_txid:` is
  the result record's txid, or nil before it is published.
  """
  @spec render(binary(), String.t(), keyword()) :: binary()
  def render(count_json, archive_sha256, opts \\ []) do
    %{"input" => input, "result" => result} = Jason.decode!(count_json)
    election = input["election"]
    names = Map.new(election["candidates"], &{&1["id"], &1["name"] || &1["id"]})

    page(%{
      name: election["name"],
      election: election["election"],
      number_elected: election["number_elected"],
      opens_at_height: election["opens_at_height"],
      closes_at_height: election["closes_at_height"],
      close_block_hash: input["close_block_hash"],
      tally:
        Enum.map(result["tally"], fn %{"candidate" => id, "votes" => votes} ->
          %{
            id: id,
            name: Map.get(names, id, id),
            votes: votes,
            elected: id in result["winners"]
          }
        end),
      winners: Enum.map(result["winners"], &Map.get(names, &1, &1)),
      undecided: result["undecided"],
      counted: result["counted"],
      not_counted: result["not_counted"],
      archive_sha256: archive_sha256,
      result_txid: Keyword.get(opts, :result_txid)
    })
    |> IO.iodata_to_binary()
  end

  EEx.function_from_file(:defp, :page, @template, [:assigns])

  defp h(value), do: value |> to_string() |> Plug.HTML.html_escape()

  defp votes(1), do: "1 vote"
  defp votes(n), do: "#{n} votes"

  defp seats(1), do: "1 seat"
  defp seats(n), do: "#{n} seats"
end
