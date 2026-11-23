defmodule BitblocksWeb.Plugs.RateLimiter.AiCrawlers do
  @moduledoc """
  The AI and LLM crawlers we recognise by user agent, grouped by the company
  that runs them, so one company's crawler shares one budget however many
  addresses it crawls from (#107).

  On 2026-11-18 `meta-externalagent/1.1` made 31,613 requests from 135 IPs in
  57.141.0.0/16, 88% of the day's traffic, and the per-IP limit never fired.
  Counted by family, the same traffic meets one small budget, and past it the
  answer is a 402 pointing at paid access (`/pricing#crawlers`): a doorway, not a
  wall.

  Ordinary search crawlers (Googlebot, Bingbot, Applebot, DuckDuckBot) are not
  on this list and keep the anonymous per-IP budget.

  ## Where the list comes from

  Each operator's published crawler documentation, cross-checked against the
  community list at https://github.com/ai-robots-txt/ai.robots.txt, as of
  2026-11-18, plus `meta-externalagent` as our own prod logs show it (a Chrome
  or Edge user agent with `compatible; meta-externalagent/1.1` appended).

  `Google-Extended` and `Applebot-Extended` are robots.txt product tokens:
  Google and Apple crawl with Googlebot and Applebot and read the token only
  to decide training use, so a request rarely carries it. They are listed so
  that a request which does is counted with its family.

  Matching is a case-insensitive substring search over the `user-agent`
  header. To add a crawler, add its token to its family here; nothing else
  changes.

  ## User-triggered fetchers

  Some companies send a separate agent when a person asks their assistant to
  read one page (`ChatGPT-User`, `Claude-User`, `Perplexity-User`,
  `meta-externalfetcher`). They are listed with their company's crawlers and
  share that company's one budget: a company is one caller, however it reads.
  A person's one question is covered by the shared anonymous budget's room and
  by the free key (`/start`), not by a bucket of its own.
  """

  # {family, [user-agent tokens]}. The family names the budget
  # (`crawler:<family>`) and the counts; keep them short, lowercase and stable.
  # A company's user-triggered fetcher is listed with its crawlers.
  @families [
    {"meta", ["meta-externalagent", "FacebookBot", "meta-externalfetcher"]},
    {"openai", ["GPTBot", "OAI-SearchBot", "ChatGPT-User"]},
    {"anthropic", ["ClaudeBot", "Claude-SearchBot", "anthropic-ai", "Claude-User"]},
    {"common_crawl", ["CCBot"]},
    {"bytedance", ["Bytespider"]},
    {"perplexity", ["PerplexityBot", "Perplexity-User"]},
    {"amazon", ["Amazonbot"]},
    {"google", ["Google-Extended"]},
    {"apple", ["Applebot-Extended"]},
    {"cohere", ["cohere-ai", "cohere-training-data-crawler"]},
    {"diffbot", ["Diffbot"]}
  ]

  @patterns for {family, tokens} <- @families,
                token <- tokens,
                do: {String.downcase(token), family}

  @doc "Every family with its user-agent tokens, in the order they're matched."
  @spec families() :: [{String.t(), [String.t()]}]
  def families, do: @families

  @doc """
  The crawler family a user agent belongs to, or nil for anything else
  (browsers, search crawlers, scripts).
  """
  @spec family(String.t() | nil) :: String.t() | nil
  def family(nil), do: nil
  def family(""), do: nil

  def family(user_agent) when is_binary(user_agent) do
    ua = String.downcase(user_agent)

    Enum.find_value(@patterns, fn {token, family} ->
      if String.contains?(ua, token), do: family
    end)
  end

  def family(_), do: nil

  # Pipelines that refuse a caller with no key and no session while the
  # sign-in gate is on (BitblocksWeb.AdminAuth), and the one that always does
  # (ops_api wants a key with a scope).
  @gated_pipelines [
    :api,
    :public_api,
    :public_csv,
    :raw_api,
    :admin,
    :signed_in,
    :admin_data,
    :admin_json
  ]
  @key_only_pipelines [:ops_api]

  @doc """
  True when an x402 payment would actually be served: the route exists and is
  open to a caller with no key and no session. A payment never buys more
  access than the free budget had, so a route that would answer 401 or 404
  after the money moved is never offered for sale.
  """
  @spec payable?(Plug.Conn.t()) :: boolean()
  def payable?(%Plug.Conn{} = conn) do
    case Phoenix.Router.route_info(BitblocksWeb.Router, conn.method, conn.path_info, conn.host) do
      %{pipe_through: pipes} ->
        gated = if BitblocksWeb.AdminAuth.enabled?(), do: @gated_pipelines, else: []
        not Enum.any?(pipes, &(&1 in gated or &1 in @key_only_pipelines))

      :error ->
        false
    end
  end

  @doc "The page that tells a crawler's operator how to get a key."
  @spec page_url() :: String.t()
  def page_url, do: "https://bitblocks.app/pricing#crawlers"

  @doc """
  Where to ask for a key. The address the `/pricing` page already offers for
  custom access; there is no checkout yet (#61).
  """
  @spec contact_email() :: String.t()
  def contact_email, do: "enterprise@bitblocks.app"
end
