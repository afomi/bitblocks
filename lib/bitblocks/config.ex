defmodule Bitblocks.Config do
  @moduledoc """
  Centralized configuration access for the Bitblocks application.

  This module provides a single source of truth for application configuration,
  making it easier to find and update configuration values.
  """

  @doc """
  Returns the Bitcoin node RPC URL.

  ## Examples

      iex> bitcoin_url()
      "http://localhost:8332"

  """
  def bitcoin_url do
    Application.get_env(:bitblocks, :bitcoin_url)
  end

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
end
