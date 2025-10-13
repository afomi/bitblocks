defmodule BitblocksWeb.PageHTML do
  use BitblocksWeb, :html
  import BitblocksWeb.RpcNodeStatusComponent

  embed_templates "page_html/*"

  def format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(number), do: to_string(number)
end
