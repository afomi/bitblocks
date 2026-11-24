defmodule BitblocksWeb.PaymentRequiredHTML do
  @moduledoc """
  The body of the 402 that `BitblocksWeb.Plugs.RateLimiter` sends past a
  shared budget: an AI crawler family's, or the one every caller with no key
  and no session shares. It is a doorway, not a wall: it says why, then the
  ways in, in order (sign in, a free key by signing a challenge, a plan, and
  for agents, paying for the request with x402 or in BSV, each when it's on).

  JSON under `/api/`, a short HTML page for a caller that accepts
  `text/html`, plain text for everyone else.
  """
  use BitblocksWeb, :html

  alias BitblocksWeb.Plugs.RateLimiter
  alias BitblocksWeb.Plugs.RateLimiter.AiCrawlers

  embed_templates "payment_required_html/*"

  @type refusal :: %{
          tier: :anonymous_site | {:ai_crawler, String.t()},
          limit: pos_integer(),
          retry_after_s: pos_integer(),
          x402: boolean(),
          bsv: boolean(),
          bsv_refused: map() | nil
        }

  @doc "`{content_type, body}` for this refusal."
  @spec body(Plug.Conn.t(), refusal()) :: {String.t(), iodata()}
  def body(%Plug.Conn{path_info: ["api" | _]}, refusal) do
    {"application/json", Jason.encode!(json(refusal))}
  end

  def body(conn, refusal) do
    if html?(conn) do
      assigns = %{
        why: why(refusal),
        retry_after_s: refusal.retry_after_s,
        x402: refusal.x402,
        bsv: bsv?(refusal),
        signed_in_budget: RateLimiter.signed_in_max_requests(),
        sign_in_path: "/sign-in?" <> URI.encode_query(%{"return_to" => return_to(conn)}),
        plans_path: "/pricing#crawlers",
        contact_email: AiCrawlers.contact_email()
      }

      html = assigns |> page() |> Phoenix.HTML.Safe.to_iodata()
      {"text/html", ["<!DOCTYPE html>\n" | html]}
    else
      {"text/plain", text(refusal)}
    end
  end

  defp html?(conn) do
    conn
    |> Plug.Conn.get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  # Back to the page refused, once signed in (UserAuth.safe_return_to/1 checks it).
  defp return_to(%Plug.Conn{method: "GET", request_path: path}), do: path
  defp return_to(_conn), do: "/"

  # One sentence: whose budget was spent, and how big it is.
  defp why(%{tier: {:ai_crawler, family}, limit: limit}) do
    "You are rate-limited as an AI crawler (#{family}): #{limit} requests a minute, " <>
      "shared by every address your crawler uses."
  end

  defp why(%{tier: :anonymous_site, limit: limit}) do
    "Everyone reading Bitblocks without a key shares #{limit} requests a minute, " <>
      "and that budget is spent for now."
  end

  defp site, do: BitblocksWeb.Endpoint.url()

  defp bsv?(refusal), do: Map.get(refusal, :bsv, false) == true

  # The ways in, for JSON and text alike, in the order a caller should try them.
  defp ways_in(x402?, bsv?) do
    ways = %{
      sign_in: site() <> "/sign-in",
      free_key: site() <> "/start",
      key_challenge: site() <> "/api/v1/keys/challenge",
      plans: AiCrawlers.page_url(),
      pay_per_request: %{
        protocol: "x402",
        offered: x402?,
        header: "PAYMENT-SIGNATURE",
        about: "https://x402.org"
      }
    }

    # Only while it's on: no terms show that can't be paid.
    if bsv?,
      do:
        Map.put(ways, :pay_in_bsv, %{
          protocol: "BRC-121",
          terms: ["x-bsv-sats", "x-bsv-server"],
          headers: Bitblocks.Payments.Bsv402.payment_headers(),
          about: "https://github.com/bitcoin-sv/BRCs/blob/master/payments/0121.md"
        }),
      else: ways
  end

  defp json(%{tier: tier} = refusal) do
    {error, family} =
      case tier do
        {:ai_crawler, family} -> {"ai_crawler_rate_limited", family}
        :anonymous_site -> {"anonymous_rate_limited", nil}
      end

    %{
      error: error,
      message: why(refusal) <> " Reading at scale takes a key; a key is free to get.",
      budget: if(family, do: "crawler_family", else: "anonymous_site"),
      crawler_family: family,
      limit_per_minute: refusal.limit,
      retry_after_seconds: refusal.retry_after_s,
      paid_access: %{
        message:
          "A key gets its own budget, and is never counted with callers that have none. " <>
            "Heavy use is paid: a plan raises a key's budget.",
        get_a_key: AiCrawlers.page_url(),
        contact: "mailto:" <> AiCrawlers.contact_email(),
        header: "Authorization: Bearer bbk_…"
      },
      ways_in: ways_in(refusal.x402, bsv?(refusal))
    }
    |> put_bsv_refused(Map.get(refusal, :bsv_refused))
  end

  # Why a BSV payment on this request wasn't taken.
  defp put_bsv_refused(json, %{reason: reason, detail: detail}),
    do: Map.put(json, :payment_refused, %{protocol: "BRC-121", reason: reason, message: detail})

  defp put_bsv_refused(json, _refused), do: json

  defp text(refusal) do
    ways = ways_in(refusal.x402, bsv?(refusal))

    x402 =
      if refusal.x402,
        do:
          "4. For agents, pay for this request with x402: this response carries a " <>
            "PAYMENT-REQUIRED offer; send the same request again with a PAYMENT-SIGNATURE header.\n",
        else: ""

    bsv =
      if bsv?(refusal),
        do:
          "5. Or pay for this request in BSV (BRC-121): this response carries x-bsv-sats and " <>
            "x-bsv-server; send the same request again with x-bsv-beef, x-bsv-sender, " <>
            "x-bsv-nonce, x-bsv-time and x-bsv-vout.\n",
        else: ""

    """
    402 Payment Required

    #{why(refusal)}
    The free budget opens again in #{refusal.retry_after_s} seconds.

    Reading at scale takes a key. A key is free to get, and heavy use is paid.

    1. Sign in with GitHub, for a budget of your own: #{ways.sign_in}
    2. Get a free API key by signing a challenge: #{ways.free_key}
       Agents: GET #{ways.key_challenge}, then POST /api/v1/keys
    3. Plans for heavy use: #{ways.plans}
    #{x402}#{bsv}
    Send a key as: Authorization: Bearer bbk_…
    Contact: #{AiCrawlers.contact_email()}

    robots.txt disallows /transactions, /blocks and /api/ for every crawler; the API is the way to the chain.
    """
  end
end
