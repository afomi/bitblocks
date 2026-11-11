defmodule BitblocksWeb.PageHTML do
  use BitblocksWeb, :html

  embed_templates "page_html/*"

  def format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(number), do: to_string(number)

  @doc """
  How much of the chain, by block count, is indexed from genesis: blocks
  0..`complete_through` of 0..`tip`, as a whole percent rounded down, so the
  bar never claims more than is done.
  """
  def coverage_share(complete_through, tip)
      when is_integer(complete_through) and is_integer(tip) and tip >= 0 do
    (complete_through + 1)
    |> Kernel.*(100)
    |> div(tip + 1)
    |> min(100)
    |> max(0)
  end
end
