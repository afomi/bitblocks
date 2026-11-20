defmodule BitblocksWeb.Api.KeyController do
  @moduledoc """
  An API key for whoever signs a bitblocks challenge (#121), with no account.

  `GET /api/v1/keys/challenge` gives a message to sign and a `challenge`, a
  token only this site can make, good for five minutes. `POST /api/v1/keys`
  with the challenge and a Bitcoin Signed Message signature over the message
  issues a key bound to the address that signed (`Bitblocks.ApiKeys.issue_signed/4`),
  shown once. Signing again replaces that address's key.

  The address is recovered from the signature, so it's optional, but send it:
  a signature over other text still recovers to *some* key, and only the
  address you expect lets us tell you so.

  Keypairs cost nothing, so redeeming is limited per IP and across the site.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.ApiKeys
  alias BitblocksWeb.Plugs.RateLimiter
  alias BitblocksWeb.Utils.IpHelper

  @salt "api key challenge v1"

  @doc "GET /api/v1/keys/challenge"
  def challenge(conn, _params) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    issued_at = DateTime.utc_now() |> DateTime.truncate(:second)
    token = Phoenix.Token.sign(conn, @salt, %{"n" => nonce, "t" => DateTime.to_unix(issued_at)})

    json(conn, %{
      data: %{
        message: ApiKeys.challenge_message(site(), nonce, issued_at),
        challenge: token,
        expires_at: ApiKeys.challenge_expires_at(issued_at),
        sign_as: "Bitcoin Signed Message, base64",
        redeem: "POST /api/v1/keys with challenge, signature and your address"
      }
    })
  end

  @doc "POST /api/v1/keys"
  def create(conn, %{"challenge" => token, "signature" => signature})
      when is_binary(token) and is_binary(signature) do
    with {:ok, %{"n" => nonce, "t" => t}} <-
           Phoenix.Token.verify(conn, @salt, token, max_age: ApiKeys.challenge_max_age_s()),
         :ok <- within_limits(conn) do
      message = ApiKeys.challenge_message(site(), nonce, DateTime.from_unix!(t))

      case ApiKeys.issue_signed(message, signature, nonce, address: address_param(conn)) do
        {:ok, key, secret} ->
          conn
          |> put_status(201)
          |> json(%{
            data: %{
              key: secret,
              prefix: key.prefix,
              address: key.address,
              requests_per_minute: key.requests_per_minute,
              note:
                "This key is shown once. Sign a new challenge with the same key to replace it."
            }
          })

        {:error, :challenge_used} ->
          error(conn, 409, "challenge already used; get a new one")

        {:error, {:wrong_signer, recovered}} ->
          error(
            conn,
            401,
            "the signature is from #{recovered}, not the address given; " <>
              "check the key, and that you signed the message exactly as given"
          )

        {:error, :bad_signature} ->
          error(conn, 401, "the signature doesn't verify over this challenge's message")

        {:error, :conflict} ->
          error(conn, 409, "another key was issued for this address just now; try again")
      end
    else
      {:error, :expired} ->
        error(conn, 401, "challenge expired; get a new one")

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> error(429, "too many keys issued; try again in a minute")

      _ ->
        error(conn, 401, "not a challenge from this site")
    end
  end

  def create(conn, _params),
    do: error(conn, 400, "send challenge and signature, from GET /api/v1/keys/challenge")

  defp within_limits(conn) do
    ip = conn |> IpHelper.get_ip_address() |> to_string()

    if RateLimiter.allow?("signed_key:ip:#{ip}", limit(:signed_keys_per_ip_per_minute, 3)) and
         RateLimiter.allow?("signed_key:all", limit(:signed_keys_per_minute, 30)),
       do: :ok,
       else: {:error, :rate_limited}
  end

  defp limit(key, default), do: Application.get_env(:bitblocks, key, default)

  defp address_param(conn) do
    case conn.params["address"] do
      address when is_binary(address) and address != "" -> address
      _ -> nil
    end
  end

  # The site the wallet sees it's signing for: our configured host, never the
  # request's Host header.
  defp site, do: "https://" <> (BitblocksWeb.Endpoint.config(:url)[:host] || "localhost")

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
