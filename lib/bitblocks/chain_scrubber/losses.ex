defmodule Bitblocks.ChainScrubber.Losses do
  @moduledoc """
  Classified losses the scrubber annotates: events the chain records exactly
  but says nothing about, such as an NFT spent by software that saw only its
  satoshis.

  The record is `priv/data/losses.json`, derived from the field note each
  entry cites. Only entries whose classification is settled appear; a
  tracing doubt (#46) stays in the note's data file with `confidence: open`
  and never reaches this list. Nothing here is computed or guessed at
  runtime: an entry exists because a person read the transactions and wrote
  the note.
  """

  @type loss :: %{
          kind: String.t(),
          collection: String.t(),
          item: String.t(),
          origin: String.t(),
          spender: String.t(),
          height: non_neg_integer(),
          date: String.t(),
          note: String.t(),
          note_url: String.t()
        }

  @doc "The classified losses, lowest height first."
  @spec classified() :: [loss()]
  def classified do
    %{"note" => note, "note_url" => note_url, "losses" => losses} = load()

    losses
    |> Enum.map(fn l ->
      %{
        kind: l["kind"],
        collection: l["collection"],
        item: l["item"],
        origin: l["origin"],
        spender: l["spender"],
        height: l["height"],
        date: l["date"],
        note: note,
        note_url: note_url
      }
    end)
    |> Enum.sort_by(& &1.height)
  end

  @doc "The file the losses come from."
  @spec path() :: String.t()
  def path, do: Path.join(:code.priv_dir(:bitblocks) |> to_string(), "data/losses.json")

  defp load do
    path() |> File.read!() |> Jason.decode!()
  end
end
