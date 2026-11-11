defmodule Bitblocks.HTTP do
  @moduledoc """
  Outbound HTTP on Finch (`Bitblocks.Finch`), the one client for every call we
  make: the node's RPC and REST, WhatsOnChain, CoinGecko, GorillaPool,
  projection webhooks, ip-api and, through `Bitblocks.HTTP.ExAwsClient`, S3 and
  EC2. It replaced HTTPoison and hackney 1.x (#65).

  Returns `{:ok, %Finch.Response{status: _, headers: _, body: _}}` for any
  status, or `{:error, reason}` with the bare transport reason
  (`:econnrefused`, `:timeout`, `:nxdomain`, `:closed`, ...), so callers keep
  the shapes they had under HTTPoison.

  Options:

    * `:receive_timeout` - the longest wait for each chunk of the response
      (HTTPoison's `:recv_timeout`); default 15 s.
    * `:request_timeout` - a bound on the whole response; default none.
    * `:pool_timeout` - the longest wait for a free connection; default 5 s.
    * `:max_body_length` - a body over this many bytes is refused with
      `{:error, :body_too_large}` as soon as it passes the limit, so it is
      never held whole in memory.

  The connect timeout is the pool's (`Bitblocks.HTTP.finch_child_spec/0`), and
  no redirect is ever followed.
  """

  @finch Bitblocks.Finch

  @connect_timeout 10_000

  @type method :: :get | :post | :put | :delete | :head | :patch | :options
  @type headers :: [{String.t(), String.t()}]

  @doc """
  The Finch child for the application's supervisor: up to 100 connections per
  host, as the hackney pool allowed, and a 10 s connect timeout.
  """
  @spec finch_child_spec() :: {module(), keyword()}
  def finch_child_spec do
    {Finch,
     name: @finch,
     pools: %{
       default: [size: 100, conn_opts: [transport_opts: [timeout: @connect_timeout]]]
     }}
  end

  @doc """
  Starts the Finch pool outside the application's supervisor, for
  `bin/bitblocks eval` and mix tasks, where the app isn't running. A no-op
  when the pool is already up.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    {:ok, _} = Application.ensure_all_started(:finch)

    if Process.whereis(@finch) do
      :ok
    else
      {Finch, opts} = finch_child_spec()

      case Finch.start_link(opts) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end

  @doc "A GET. See the module doc for options and return shapes."
  @spec get(String.t(), headers(), keyword()) :: {:ok, Finch.Response.t()} | {:error, term()}
  def get(url, headers \\ [], opts \\ []), do: request(:get, url, headers, nil, opts)

  @doc "A POST. See the module doc for options and return shapes."
  @spec post(String.t(), iodata() | nil, headers(), keyword()) ::
          {:ok, Finch.Response.t()} | {:error, term()}
  def post(url, body, headers \\ [], opts \\ []), do: request(:post, url, headers, body, opts)

  @doc "Any request. See the module doc for options and return shapes."
  @spec request(method(), String.t(), headers(), iodata() | nil, keyword()) ::
          {:ok, Finch.Response.t()} | {:error, term()}
  def request(method, url, headers, body, opts \\ []) do
    {max_body, opts} = Keyword.pop(opts, :max_body_length)
    opts = Keyword.take(opts, [:receive_timeout, :request_timeout, :pool_timeout])
    body = if body == "", do: nil, else: body

    with {:ok, req} <- build(method, url, headers, body) do
      if max_body, do: capped(req, max_body, opts), else: plain(req, opts)
    end
  end

  defp build(method, url, headers, body) do
    {:ok, Finch.build(method, url, headers, body)}
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  defp plain(req, opts) do
    case Finch.request(req, @finch, opts) do
      {:ok, %Finch.Response{} = resp} -> {:ok, resp}
      {:error, error} -> {:error, reason(error)}
    end
  catch
    :exit, exit_reason -> {:error, exit_reason(exit_reason)}
  end

  defp capped(req, max_body, opts) do
    acc = %{status: nil, headers: [], body: [], size: 0}

    fun = fn
      {:status, status}, acc ->
        {:cont, %{acc | status: status}}

      {:headers, headers}, acc ->
        {:cont, %{acc | headers: acc.headers ++ headers}}

      {:data, data}, acc ->
        size = acc.size + byte_size(data)

        if size > max_body,
          do: {:halt, %{acc | size: size, body: :too_large}},
          else: {:cont, %{acc | size: size, body: [acc.body | data]}}

      {:trailers, _}, acc ->
        {:cont, acc}
    end

    case Finch.stream_while(req, @finch, acc, fun, opts) do
      {:ok, %{body: :too_large}} ->
        {:error, :body_too_large}

      {:ok, %{status: status, headers: headers, body: body}} ->
        {:ok, %Finch.Response{status: status, headers: headers, body: IO.iodata_to_binary(body)}}

      {:error, error, _acc} ->
        {:error, reason(error)}
    end
  catch
    :exit, exit_reason -> {:error, exit_reason(exit_reason)}
  end

  defp reason(%{reason: reason}), do: reason
  defp reason(other), do: other

  # NimblePool exits when no connection frees up within :pool_timeout.
  defp exit_reason({:timeout, _}), do: :checkout_timeout
  defp exit_reason(other), do: {:exit, other}
end
