defmodule BitblocksWeb.RawBodyReader do
  @moduledoc """
  `Plug.Parsers`' body reader: keeps the exact request body in
  `conn.private[:raw_body]` for the paths that verify a signature over it
  (the Stripe webhook, `BitblocksWeb.StripeWebhookController`), and reads
  every other body as Plug does.
  """

  @raw_paths ["/webhooks/stripe"]

  @doc false
  def read_body(%Plug.Conn{request_path: path} = conn, opts) when path in @raw_paths do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, append(conn, body)}

      {:more, body, conn} ->
        {:more, body, append(conn, body)}

      {:error, _} = error ->
        error
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  defp append(conn, chunk) do
    Plug.Conn.put_private(conn, :raw_body, (conn.private[:raw_body] || "") <> chunk)
  end

  @doc "The paths whose raw body is kept."
  def raw_paths, do: @raw_paths
end
