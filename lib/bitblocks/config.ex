defmodule Bitblocks.Config do
  @moduledoc """
  Centralized configuration access for the Bitblocks application.

  This module provides a single source of truth for application configuration,
  making it easier to find and update configuration values.
  """

  @doc """
  Returns the Bitcoin node RPC URL.

  `BITCOIN_NODE_RPC_URL` (`:rpc_url`) wins over `BITCOIN_NODE_URL`
  (`:bitcoin_url`), matching `config/runtime.exs`. Either may point at a
  public no-auth endpoint such as `https://bsv-rpc.publicnode.com`; leave the
  RPC username and password unset there.

  ## Examples

      iex> bitcoin_url()
      "http://localhost:8332"

  """
  def bitcoin_url do
    present(Application.get_env(:bitblocks, :rpc_url)) ||
      present(Application.get_env(:bitblocks, :bitcoin_url))
  end

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: String.trim(value)
  end

  defp present(_), do: nil

  @doc """
  Returns the Bitcoin RPC username.

  ## Examples

      iex> rpc_user()
      "bitcoin"

  """
  def rpc_user do
    Application.get_env(:bitblocks, :rpc_user)
  end

  @doc """
  Returns the Bitcoin RPC password.

  ## Examples

      iex> rpc_password()
      "password"

  """
  def rpc_password do
    Application.get_env(:bitblocks, :rpc_password)
  end

  @doc """
  Returns whether to fetch full transaction details during sync.

  Defaults to false.

  ## Examples

      iex> fetch_full_transactions?()
      false

  """
  def fetch_full_transactions? do
    Application.get_env(:bitblocks, :fetch_full_transactions, false)
  end

  @doc """
  Returns the maximum number of transactions to fetch per block during sync.

  Defaults to 1000.

  ## Examples

      iex> max_transactions_per_block()
      1000

  """
  def max_transactions_per_block do
    Application.get_env(:bitblocks, :max_transactions_per_block, 1000)
  end

  @doc """
  Returns the DNS cluster query configuration.

  ## Examples

      iex> dns_cluster_query()
      nil

  """
  def dns_cluster_query do
    Application.get_env(:bitblocks, :dns_cluster_query)
  end

  @doc """
  Returns the Oban configuration.

  ## Examples

      iex> oban_config()
      [repo: Bitblocks.Repo, queues: [...]]

  """
  def oban_config do
    Application.fetch_env!(:bitblocks, Oban)
  end

  @doc """
  What a `getblockchaininfo` answer says about the node.

  `-28` (RPC_IN_WARMUP: "Loading block index...", "Verifying blocks...") is
  a reachable node still starting after a restart, not a failure.
  """
  @spec node_status(term()) ::
          :ok | {:warming_up, String.t()} | {:unreachable, term()}
  def node_status(%{"chain" => _}), do: :ok
  def node_status({:error, %{"code" => -28} = error}), do: {:warming_up, error["message"] || ""}
  def node_status({:error, reason}), do: {:unreachable, reason}
  def node_status(other), do: {:unreachable, other}

  @doc """
  The node URL with its host hidden, for pages: "http://•••:8332".
  The node's address never appears on the site (this repo and site are public).
  """
  @spec masked_node_url(String.t() | nil) :: String.t() | nil
  def masked_node_url(nil), do: nil

  def masked_node_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, port: port} when is_binary(scheme) ->
        "#{scheme}://•••" <> if(port, do: ":#{port}", else: "")

      _ ->
        "•••"
    end
  end
end
