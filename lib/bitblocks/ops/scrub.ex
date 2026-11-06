defmodule Bitblocks.Ops.Scrub do
  @moduledoc """
  Takes what an operator session must not see out of a line of text (#50).

  Everything that leaves `Bitblocks.Ops` for a key holder passes through here
  when it could carry free text: a block's last error, a log line, a node
  message. Those texts come from `inspect/1` on an arbitrary reason, so the
  rule is by shape, and it errs towards removing too much:

    * URLs of any scheme, whole (`postgres://user:pass@host/db`).
    * IPv4 and IPv6 addresses, and an inspected `{10, 0, 1, 5}`.
    * Host names on a public or internal suffix.
    * `user@host`: email addresses and Erlang node names.
    * Bitcoin addresses.
    * API keys, `Bearer` and `Basic` credentials, `password=…` and the like.
    * The exact value of every configured secret and environment variable.
  """

  @max_length 500
  # Long enough to hold real text, short enough to bound the regexes.
  @scan_length 8_000

  # An environment value shorter than this is a word or a number, not a secret.
  @min_env_value 8

  @doc "One scrubbed line, at most #{@max_length} characters; nil stays nil."
  @spec line(term()) :: String.t() | nil
  def line(nil), do: nil

  def line(text) when is_binary(text) do
    text
    |> String.slice(0, @scan_length)
    |> String.replace(~r{\b[a-z][a-z0-9+.-]*://\S+}i, "[url]")
    |> remove_known_values()
    |> remove_shapes()
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.slice(0, @max_length)
  end

  def line(term), do: term |> inspect(limit: 50, printable_limit: @scan_length) |> line()

  # Longest first, so a value inside another doesn't leave part of it behind.
  defp remove_known_values(text) do
    (configured_secrets() ++ env_values())
    |> Enum.uniq()
    |> Enum.sort_by(&(-byte_size(&1)))
    |> Enum.reduce(text, &String.replace(&2, &1, "[redacted]"))
  end

  defp configured_secrets do
    repo = Application.get_env(:bitblocks, Bitblocks.Repo, [])
    endpoint = Application.get_env(:bitblocks, BitblocksWeb.Endpoint, [])

    [
      Application.get_env(:bitblocks, :rpc_url),
      Application.get_env(:bitblocks, :bitcoin_url),
      Application.get_env(:bitblocks, :rest_url),
      Bitblocks.Config.rpc_user(),
      Bitblocks.Config.rpc_password(),
      repo[:url],
      repo[:password],
      repo[:hostname],
      endpoint[:secret_key_base]
    ]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp env_values do
    for {_name, value} <- System.get_env(), byte_size(value) >= @min_env_value, do: value
  end

  defp remove_shapes(text) do
    text
    |> String.replace(~r/\bbbk_[A-Za-z0-9_-]+/, "[key]")
    |> String.replace(~r/\b(Bearer|Basic)\s+[A-Za-z0-9+\/=._~-]+/i, "\\1 [redacted]")
    |> String.replace(secret_assignment(), "\\1=[redacted]")
    |> String.replace(~r/[\w.+-]+@[\w.\[\]:-]+/, "[host]")
    |> String.replace(~r/\b\d{1,3}(\.\d{1,3}){3}(:\d+)?\b/, "[ip]")
    |> String.replace(~r/\{\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*\}/, "[ip]")
    |> String.replace(ipv6(), "[ip]")
    |> String.replace(host(), "[host]")
    |> String.replace(~r/\b[13][a-km-zA-HJ-NP-Z1-9]{25,34}\b/, "[address]")
  end

  # password=…, token: "…", "secret" => "…"
  defp secret_assignment do
    ~r/\b(pass(?:word|wd)?|secret|token|api[_-]?key|authorization|auth|credential)s?\b"?\s*(?:=>|[=:])\s*("[^"]*"|'[^']*'|\S+)/i
  end

  defp ipv6 do
    ~r/(?<![\w:])(?:(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4})*)?::(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4})*)?)(?![\w:])/i
  end

  defp host do
    ~r/\b(?:[a-z0-9-]+\.)+(?:com|net|org|io|app|dev|cloud|local|internal|lan)\b(:\d+)?/i
  end
end
