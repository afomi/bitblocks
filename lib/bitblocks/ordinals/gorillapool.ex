defmodule Bitblocks.Ordinals.Gorillapool do
  @moduledoc """
  GorillaPool's 1Sat indexer, used only as a discovery hint: the mint txids of
  a collection's items. `Bitblocks.OrdinalCollections.sync/3` proves each one
  against the mint-contract chain, so a wrong or partial answer here can't add
  a fake item, and items it misses are found by following the chain.
  """

  @base "https://ordinals.gorillapool.io/api"
  @page 300

  @doc "Mint txids of items claiming `collection_id`, or `{:error, reason}`."
  @spec collection_mint_txids(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def collection_mint_txids(collection_id) do
    query =
      %{map: %{subTypeData: %{collectionId: collection_id}}} |> Jason.encode!() |> Base.encode64()

    fetch(query, 0, MapSet.new())
  end

  defp fetch(query, offset, acc) do
    url =
      "#{@base}/inscriptions/search?q=#{URI.encode_www_form(query)}&limit=#{@page}&offset=#{offset}"

    with {:ok, %HTTPoison.Response{status_code: 200, body: body}} <-
           HTTPoison.get(url, [], recv_timeout: 60_000),
         {:ok, rows} when is_list(rows) <- Jason.decode(body) do
      acc =
        for %{"origin" => %{"outpoint" => origin}} <- rows, into: acc do
          origin |> String.split("_") |> hd()
        end

      if length(rows) < @page,
        do: {:ok, MapSet.to_list(acc)},
        else: fetch(query, offset + @page, acc)
    else
      {:ok, %HTTPoison.Response{status_code: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end
end
