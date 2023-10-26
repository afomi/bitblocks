defmodule BitblocksWeb.PageController do
  use BitblocksWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
