defmodule BitblocksWeb.Api.UsageController do
  @moduledoc """
  `GET /api/v1/usage?hours=24`: what the calling key (or signed-in user) has
  used, by endpoint class, over the last `hours` (1 to 720, default 24), as
  `Bitblocks.Usage` measures it (https://github.com/afomi/bitblocks/issues/61).
  Measured only: nobody is charged for it. Only your own use is shown.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Usage

  @max_hours 720

  @note "Measured, not billed. Counts reach the rollups within a minute; " <>
          "this node's last minute is included, other nodes' may not be yet."

  def show(conn, params) do
    case {Usage.caller(conn), parse_hours(params["hours"])} do
      {{kind, _}, _} when kind in ["anonymous", "crawler"] ->
        conn
        |> put_status(401)
        |> json(%{error: "Send an API key, or sign in, to see your own usage"})

      {_, :error} ->
        conn
        |> put_status(400)
        |> json(%{error: "Expected hours=<1..#{@max_hours}>"})

      {caller, {:ok, hours}} ->
        usage = Usage.caller_usage(caller, hours: hours)

        json(conn, %{
          data: %{
            totals: usage.totals,
            by_class: usage.by_class
          },
          meta: %{
            caller: elem(caller, 0),
            from: usage.from,
            to: usage.to,
            hours: usage.hours,
            note: @note
          }
        })
    end
  end

  defp parse_hours(nil), do: {:ok, 24}

  defp parse_hours(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= 1 and n <= @max_hours -> {:ok, n}
      _ -> :error
    end
  end
end
