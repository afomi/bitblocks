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
  """

  # {family, [user-agent tokens]}. The family names the budget (`crawler:<family>`)
  # and the counts; keep them short, lowercase and stable.
  @families [
    {"meta", ["meta-externalagent", "meta-externalfetcher", "FacebookBot"]},
    {"openai", ["GPTBot", "ChatGPT-User", "OAI-SearchBot"]},
    {"anthropic", ["ClaudeBot", "Claude-User", "Claude-SearchBot", "anthropic-ai"]},
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
