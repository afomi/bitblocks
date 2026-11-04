defmodule BitblocksWeb.Sats do
  @moduledoc """
  How pages show satoshi amounts: thousands separators always, and a dash
  for a value we don't know. Block totals (docs/TX_PIPELINE.md) show a dash
  until the block is completed.
  """

  @doc "`1,234 sats`, or `—` when unknown."
  @spec sats(integer() | nil) :: String.t()
  def sats(nil), do: "—"
  def sats(n) when is_integer(n), do: "#{delimit(n)} sats"

  @doc "`6.25 BSV`, trailing zeros trimmed, or `—` when unknown."
  @spec bsv(integer() | nil) :: String.t()
  def bsv(nil), do: "—"

  def bsv(n) when is_integer(n) do
    whole = delimit(div(n, 100_000_000))

    case rem(abs(n), 100_000_000) do
      0 ->
        "#{whole} BSV"

      frac ->
        "#{whole}.#{frac |> Integer.to_string() |> String.pad_leading(8, "0") |> String.trim_trailing("0")} BSV"
    end
  end

  @doc "A block total in sats: `—` until the block is completed."
  def block_sats(%{sync_state: "completed"} = block, field), do: sats(Map.get(block, field))
  def block_sats(_block, _field), do: "—"

  @doc "A block total in BSV: `—` until the block is completed."
  def block_bsv(%{sync_state: "completed"} = block, field), do: bsv(Map.get(block, field))
  def block_bsv(_block, _field), do: "—"

  @doc "An integer with thousands separators."
  @spec delimit(integer()) :: String.t()
  def delimit(n) when is_integer(n) and n < 0, do: "-" <> delimit(-n)

  def delimit(n) when is_integer(n),
    do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
end
