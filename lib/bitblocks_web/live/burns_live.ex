defmodule BitblocksWeb.BurnsLive do
  @moduledoc """
  `/burns`, admin only: the blocks that burned sats, most first or newest
  first, and for a chosen block the stored txs that burned them
  (`Bitblocks.Burns`). `?order=height` and `?block=<hash>` keep both in the URL.
  """

  use BitblocksWeb, :live_view

  alias Bitblocks.Burns

  import BitblocksWeb.Sats, only: [bsv: 1, delimit: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Burns", summary: Burns.summary())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    order = if params["order"] == "height", do: :height, else: :burned
    selected = params["block"]

    {:noreply,
     assign(socket,
       order: order,
       blocks: Burns.blocks(order: order),
       selected: selected,
       txs: if(selected, do: Burns.txs(selected), else: []),
       tx_summary: if(selected, do: Burns.tx_summary(selected))
     )}
  end

  @doc false
  def burns_path(order, block \\ nil) do
    query =
      [order: if(order == :height, do: "height"), block: block]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case query do
      [] -> "/burns"
      q -> "/burns?" <> URI.encode_query(q)
    end
  end
end
