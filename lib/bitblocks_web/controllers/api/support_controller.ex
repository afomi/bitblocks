defmodule BitblocksWeb.Api.SupportController do
  @moduledoc """
  Serves `Bitblocks.Support.summary/0` for the off-site sponsorship page:
  monthly costs, the target, and BSV received at the donation address.
  """
  use BitblocksWeb, :controller

  @doc "GET /api/v1/support"
  def show(conn, _params) do
    json(conn, %{data: Bitblocks.Support.summary()})
  end
end
