defmodule BitblocksWeb.HighlightsLive do
  use BitblocksWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Blockchain Highlights",
        highlights: get_highlights()
      )

    {:ok, socket}
  end

  defp get_highlights do
    [
      %{
        id: 1,
        title: "Genesis Block - The Beginning",
        date: ~D[2009-01-03],
        category: "milestone",
        txid: "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b",
        block_height: 0,
        author: "Community",
        content: """
        The Genesis Block marks the beginning of Bitcoin. This is where it all started.
        The coinbase transaction contains the famous message: "The Times 03/Jan/2009 Chancellor on brink of second bailout for banks"
        """,
        tags: ["genesis", "milestone", "history"]
      },
      %{
        id: 2,
        title: "First Bitcoin Transaction",
        date: ~D[2009-01-12],
        category: "first",
        txid: "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16",
        block_height: 170,
        author: "Community",
        content: """
        The first Bitcoin transaction sent from one person to another. Satoshi Nakamoto sent 10 BTC to Hal Finney,
        a cryptographer and early Bitcoin contributor. This transaction proved that the system worked.
        """,
        tags: ["first", "satoshi", "hal-finney"]
      },
      %{
        id: 3,
        title: "Bitcoin Pizza Day",
        date: ~D[2010-05-22],
        category: "culture",
        txid: nil,
        block_height: 57043,
        author: "Community",
        content: """
        On this day, Laszlo Hanyecz made the first real-world transaction by buying two pizzas for 10,000 BTC.
        This day is now celebrated annually as Bitcoin Pizza Day, marking the first time Bitcoin was used to purchase a physical good.
        """,
        tags: ["pizza-day", "culture", "milestone"]
      }
    ]
  end

  # Template: highlights_live.html.heex

  defp category_color("milestone"), do: "bg-brand text-white"
  defp category_color("first"), do: "bg-green-500 text-white"
  defp category_color("culture"), do: "bg-neutral-600 text-white"
  defp category_color("nft"), do: "bg-neutral-600 text-white"
  defp category_color("record"), do: "bg-neutral-600 text-white"
  defp category_color("birthday"), do: "bg-neutral-600 text-white"
  defp category_color(_), do: "bg-neutral-600 text-white"
end
