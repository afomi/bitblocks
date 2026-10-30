defmodule Bitblocks.Rexxies.Catalog do
  @moduledoc """
  The Rexxie catalog (number and traits by mint txid), from
  `priv/data/rexxie-collection.json` (exported by rexxie-indexer from
  RelayX's `content.js`).

  This is curated metadata, not chain data: RelayX mints carry empty metadata
  and an encrypted image, so number and traits can't be derived from the
  bytes. Each trait is tagged `"source" => "catalog"` so readers can tell.
  Which txs are Rexxie mints is proven on chain (`OrdinalCollections.RunJig`);
  the catalog only names them.
  """

  @key {__MODULE__, :entries}

  @doc "Catalog entry for a mint txid: `%{number, name, traits}`, or nil."
  def entry(txid), do: Map.get(entries(), txid)

  @doc "Every catalogued mint txid (a sync hint; each is still proven on chain)."
  def mint_txids, do: Map.keys(entries())

  defp entries do
    case :persistent_term.get(@key, nil) do
      nil ->
        entries = load()
        :persistent_term.put(@key, entries)
        entries

      entries ->
        entries
    end
  end

  @traits ~w(background base body eye mouth head)

  defp load do
    path = Path.join(:code.priv_dir(:bitblocks), "data/rexxie-collection.json")

    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.new(fn %{"txid" => txid, "number" => number} = row ->
      {txid,
       %{
         number: String.to_integer(to_string(number)),
         name: "Rexxie ##{number}",
         traits:
           for t <- @traits, row[t] do
             %{"name" => t, "value" => row[t], "description" => nil, "source" => "catalog"}
           end
       }}
    end)
  end
end
