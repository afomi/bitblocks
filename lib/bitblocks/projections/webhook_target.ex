defmodule Bitblocks.Projections.WebhookTarget do
  @moduledoc """
  Where a projection's webhook may point (#29 step 5): a public host only, so
  a webhook can't aim Bitblocks at its own network (SSRF).

  Checked twice. `check/1` runs when a URL is set, and refuses a private
  address or name at once, with a reason. `resolve/1` runs before every
  delivery, because a name that was public when it was set can resolve
  elsewhere later.

  Every address a name resolves to must be public: one private answer refuses
  the delivery.

  A name can also change between the check and the connection (DNS rebinding).
  So an `http` delivery connects to the checked address itself, with the name
  in its `host` header. An `https` delivery connects by name: the certificate
  must match that name, which a host on our network can't present. Deliveries
  follow no redirects (`Projections.Webhook.post/3`).
  """

  # Names that only mean something inside a network.
  @private_suffixes ~w(.localhost .local .internal .intranet .lan .home .corp)

  @typedoc "An address as `:inet` gives it."
  @type address :: :inet.ip_address()

  @doc "`:ok`, or `{:error, reason}` in words. For validating a URL as it is set."
  @spec check(String.t()) :: :ok | {:error, String.t()}
  def check(url) do
    case resolve(url) do
      {:refused, reason} -> {:error, reason}
      # A lookup that fails today may work tomorrow; delivery checks again.
      _ -> :ok
    end
  end

  @doc """
  What to connect to for `url`, just before delivering:

    * `{:ok, url, headers}`: post there, adding those headers.
    * `{:refused, reason}`: this target isn't allowed, and won't become so.
    * `{:retry, reason}`: the name didn't resolve; try again later.
  """
  @spec resolve(String.t()) ::
          {:ok, String.t(), [{String.t(), String.t()}]}
          | {:refused, String.t()}
          | {:retry, term()}
  def resolve(url) when is_binary(url) do
    with {:ok, uri} <- parse(url),
         {:ok, addresses} <- addresses(uri.host) do
      connect_to(uri, url, addresses)
    end
  end

  defp parse(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme not in ["https", "http"] or host in [nil, ""] ->
        {:refused, "must be an http(s) URL"}

      %URI{userinfo: userinfo} when not is_nil(userinfo) ->
        {:refused, "must not carry a user or password"}

      uri ->
        {:ok, uri}
    end
  end

  defp addresses(host) do
    lower = String.downcase(host)

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        allowed([address])

      {:error, _} ->
        cond do
          private_name?(lower) -> {:refused, "must be a public host"}
          true -> lookup(host)
        end
    end
  end

  defp private_name?(host) do
    not String.contains?(host, ".") or String.ends_with?(host, @private_suffixes)
  end

  defp lookup(host) do
    case resolver().addresses(host) do
      [] -> {:retry, :nxdomain}
      addresses -> allowed(addresses)
    end
  end

  defp allowed(addresses) do
    if Enum.all?(addresses, &public?/1),
      do: {:ok, addresses},
      else: {:refused, "must be a public host"}
  end

  defp connect_to(%URI{scheme: "https"}, url, _addresses), do: {:ok, url, []}

  defp connect_to(%URI{} = uri, _url, [address | _]) do
    host_header =
      if uri.port in [nil, URI.default_port(uri.scheme)],
        do: uri.host,
        else: "#{uri.host}:#{uri.port}"

    pinned = %{uri | host: address |> :inet.ntoa() |> to_string()}
    {:ok, URI.to_string(pinned), [{"host", host_header}]}
  end

  @doc "True for an address on the public internet."
  @spec public?(address()) :: boolean()
  def public?({a, b, c, _d}) do
    not (a == 0 or a == 10 or a == 127 or a >= 224 or
           (a == 100 and b in 64..127) or
           (a == 169 and b == 254) or
           (a == 172 and b in 16..31) or
           (a == 192 and b == 0 and c in [0, 2]) or
           (a == 192 and b == 168) or
           (a == 198 and b in 18..19) or
           (a == 198 and b == 51 and c == 100) or
           (a == 203 and b == 0 and c == 113))
  end

  # Unspecified, loopback and the deprecated IPv4-compatible range.
  def public?({0, 0, 0, 0, 0, 0, _, _}), do: false
  # IPv4-mapped and NAT64: the IPv4 address inside decides.
  def public?({0, 0, 0, 0, 0, 0xFFFF, g, h}), do: public?(embedded(g, h))
  def public?({0x64, 0xFF9B, 0, 0, 0, 0, g, h}), do: public?(embedded(g, h))
  # 6to4 carries its IPv4 address right after the prefix.
  def public?({0x2002, b, c, _, _, _, _, _}), do: public?(embedded(b, c))
  # Documentation.
  def public?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: false

  def public?({a, _, _, _, _, _, _, _}) do
    # Unique local fc00::/7, link-local fe80::/10, site-local fec0::/10, multicast ff00::/8.
    Bitwise.band(a, 0xFE00) != 0xFC00 and Bitwise.band(a, 0xFF80) != 0xFE80 and
      Bitwise.band(a, 0xFF00) != 0xFF00
  end

  defp embedded(high, low) do
    {Bitwise.bsr(high, 8), Bitwise.band(high, 0xFF), Bitwise.bsr(low, 8), Bitwise.band(low, 0xFF)}
  end

  defp resolver, do: Application.get_env(:bitblocks, :webhook_resolver, __MODULE__.Dns)

  defmodule Dns do
    @moduledoc false

    @doc "Every address `host` resolves to, IPv4 and IPv6; `[]` when none."
    def addresses(host) do
      name = String.to_charlist(host)

      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(name, family) do
          {:ok, addresses} -> addresses
          {:error, _} -> []
        end
      end)
    end
  end
end
