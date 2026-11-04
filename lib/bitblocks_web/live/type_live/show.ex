defmodule BitblocksWeb.TypeLive.Show do
  @moduledoc """
  `/types/:id`: one transaction type. Its description, background, spec link,
  labelled script pattern, how it is spent, related types, and real
  transactions from the index (`Bitblocks.TxTypes.Examples`).
  An unknown id is a 404.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.TxTypes
  alias Bitblocks.TxTypes.Examples
  alias BitblocksWeb.Seo

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    type = TxTypes.get!(id)

    {:ok,
     socket
     |> assign(
       Seo.public_page(
         page_title: "#{type.title}: a Bitcoin SV transaction type",
         meta_description: type.summary,
         canonical_path: "/types/#{type.id}"
       )
     )
     |> assign(
       type: type,
       related: TxTypes.related(type),
       examples: Examples.for_type(type)
     )}
  end

  @doc "A block height with thousands separators."
  def format_height(nil), do: "unconfirmed"

  def format_height(height) when is_integer(height) do
    height
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  @doc "A count with thousands separators."
  def format_count(count) when is_integer(count), do: format_height(count)
end
