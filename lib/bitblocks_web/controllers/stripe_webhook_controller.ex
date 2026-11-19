defmodule BitblocksWeb.StripeWebhookController do
  @moduledoc """
  `POST /webhooks/stripe`: Stripe's events for paid downloads
  (https://github.com/afomi/bitblocks/issues/111, docs/STRIPE.md).

  Every delivery must carry a valid `Stripe-Signature` over its exact body
  (`Bitblocks.Payments.Stripe.verify_webhook/3`), or it is a 400 and nothing
  is read from it. A verified event is handled once by its id
  (`Bitblocks.Downloads.Purchases.handle_event/1`) and answered 200, a
  duplicate included, so Stripe stops sending it. A database failure is a
  500, so Stripe tries again later. While Checkout is dormant (no webhook
  secret), every delivery is a 503.
  """
  use BitblocksWeb, :controller

  require Logger

  alias Bitblocks.Downloads.Purchases
  alias Bitblocks.Payments.Stripe

  def create(conn, _params) do
    {raw, conn} = raw_body(conn)
    header = conn |> get_req_header("stripe-signature") |> List.first()

    case Stripe.verify_webhook(raw, header) do
      {:ok, event} ->
        case Purchases.handle_event(event) do
          {:ok, outcome} ->
            json(conn, %{received: true, outcome: outcome})

          {:error, reason} ->
            Logger.error("Stripe webhook could not be handled: #{inspect(reason)}")
            conn |> put_status(500) |> json(%{received: false})
        end

      {:error, :not_configured} ->
        conn |> put_status(503) |> json(%{error: "not_configured"})

      {:error, reason} ->
        Logger.warning("Stripe webhook refused: #{reason}")
        conn |> put_status(400) |> json(%{error: Atom.to_string(reason)})
    end
  end

  # Plug.Parsers kept the body (BitblocksWeb.RawBodyReader); a body of a type
  # no parser reads is still unread, so read it here, up to 1 MB.
  defp raw_body(conn) do
    case conn.private[:raw_body] do
      body when is_binary(body) ->
        {body, conn}

      nil ->
        case Plug.Conn.read_body(conn, length: 1_000_000) do
          {:ok, body, conn} -> {body, conn}
          {_, _, conn} -> {"", conn}
          {:error, _} -> {"", conn}
        end
    end
  end
end
