defmodule Bitblocks.Outbound do
  @moduledoc """
  Outbound transaction management using Txbox.

  This module handles the creation, signing, broadcasting, and tracking
  of transactions that originate from Bitblocks (as opposed to inbound
  transactions synced from the blockchain).

  ## Transaction Lifecycle

  Outbound transactions flow through these states:
  - `draft` - Transaction being constructed
  - `unsigned` - Transaction ready but not signed
  - `signed` - Transaction signed and ready to broadcast
  - `queued` - Queued for broadcasting via mAPI
  - `broadcasting` - Currently being submitted to miners
  - `broadcasted` - Successfully submitted to at least one miner
  - `mempool` - Confirmed in mempool (converges with inbound flow)
  - `confirming` - In a block but awaiting more confirmations
  - `confirmed_1` through `confirmed_100` - Confirmation depth tracking
  - `mature` - Fully confirmed and spendable
  - `spent` - Transaction outputs have been spent

  ## Usage

  ```elixir
  # Create a new transaction
  {:ok, tx} = Bitblocks.Outbound.create_tx(%{
    channel: "my_app",
    tags: ["payment", "user_123"],
    meta: %{description: "Payment to merchant"}
  })

  # Build the transaction with inputs/outputs
  {:ok, tx} = Bitblocks.Outbound.build_tx(tx, inputs, outputs)

  # Sign the transaction
  {:ok, tx} = Bitblocks.Outbound.sign_tx(tx, private_keys)

  # Queue for broadcasting
  {:ok, tx} = Bitblocks.Outbound.queue_tx(tx)

  # Txbox will automatically handle broadcasting and confirmation tracking
  ```

  ## Event Broadcasting

  This module broadcasts events via Phoenix.PubSub for external applications:

  - `{:tx_created, tx}` - New transaction created
  - `{:tx_signed, tx}` - Transaction signed
  - `{:tx_broadcasted, tx}` - Transaction broadcasted
  - `{:tx_confirmed, tx, confirmations}` - Transaction confirmed
  - `{:tx_error, tx, error}` - Transaction error occurred

  Subscribe to events:

  ```elixir
  Phoenix.PubSub.subscribe(Bitblocks.PubSub, "outbound_txs")
  Phoenix.PubSub.subscribe(Bitblocks.PubSub, "outbound_txs:my_channel")
  ```
  """

  alias Bitblocks.Repo
  alias Txbox.Transactions
  alias Phoenix.PubSub

  @pubsub Bitblocks.PubSub

  @doc """
  Creates a new outbound transaction.

  ## Parameters
  - `attrs` - Map with optional keys:
    - `:channel` - Channel/namespace for organizing transactions
    - `:tags` - List of tags for categorization
    - `:meta` - Metadata map (searchable via full-text search)
    - `:data` - Additional data to store with transaction

  ## Examples

      iex> Bitblocks.Outbound.create_tx(%{channel: "payments", tags: ["invoice_123"]})
      {:ok, %Txbox.Transactions.Tx{}}
  """
  def create_tx(attrs \\ %{}) do
    result = Transactions.create(attrs)

    case result do
      {:ok, tx} ->
        broadcast_event("outbound_txs", {:tx_created, tx})
        broadcast_channel_event(tx.channel, {:tx_created, tx})
        {:ok, tx}

      error ->
        error
    end
  end

  @doc """
  Builds transaction with inputs and outputs.

  ## Parameters
  - `tx` - Transaction struct or ID
  - `inputs` - List of input maps with `:txid`, `:vout`, `:script`, `:satoshis`
  - `outputs` - List of output maps with `:script`, `:satoshis`

  ## Examples

      iex> Bitblocks.Outbound.build_tx(tx, inputs, outputs)
      {:ok, %Txbox.Transactions.Tx{}}
  """
  def build_tx(tx, inputs, outputs) do
    # This would integrate with BSV library to construct the transaction
    # For now, this is a placeholder for the actual implementation
    {:ok, tx}
  end

  @doc """
  Signs a transaction with provided private keys.

  ## Parameters
  - `tx` - Transaction to sign
  - `private_keys` - List of private keys or a signing function

  ## Examples

      iex> Bitblocks.Outbound.sign_tx(tx, [private_key])
      {:ok, %Txbox.Transactions.Tx{}}
  """
  def sign_tx(tx, private_keys) do
    # This would integrate with BSV library to sign the transaction
    # For now, this is a placeholder
    result = {:ok, tx}

    case result do
      {:ok, signed_tx} ->
        broadcast_event("outbound_txs", {:tx_signed, signed_tx})
        broadcast_channel_event(signed_tx.channel, {:tx_signed, signed_tx})
        {:ok, signed_tx}

      error ->
        error
    end
  end

  @doc """
  Queues a transaction for broadcasting via mAPI.

  The transaction will be automatically submitted to configured miners
  and tracked through the confirmation process.

  ## Examples

      iex> Bitblocks.Outbound.queue_tx(tx)
      {:ok, %Txbox.Transactions.Tx{}}
  """
  def queue_tx(tx) do
    result = Transactions.push(tx)

    case result do
      {:ok, queued_tx} ->
        broadcast_event("outbound_txs", {:tx_queued, queued_tx})
        broadcast_channel_event(queued_tx.channel, {:tx_queued, queued_tx})
        {:ok, queued_tx}

      error ->
        broadcast_event("outbound_txs", {:tx_error, tx, error})
        broadcast_channel_event(tx.channel, {:tx_error, tx, error})
        error
    end
  end

  @doc """
  Gets a transaction by ID or txid.

  ## Examples

      iex> Bitblocks.Outbound.get_tx(id)
      %Txbox.Transactions.Tx{}

      iex> Bitblocks.Outbound.get_tx("txid_here")
      %Txbox.Transactions.Tx{}
  """
  def get_tx(id_or_txid) do
    Transactions.get(id_or_txid)
  end

  @doc """
  Lists transactions with optional filters.

  ## Parameters
  - `filters` - Map with optional keys:
    - `:channel` - Filter by channel
    - `:tags` - Filter by tags (any match)
    - `:state` - Filter by state
    - `:limit` - Limit results
    - `:offset` - Offset for pagination

  ## Examples

      iex> Bitblocks.Outbound.list_txs(%{channel: "payments", limit: 10})
      [%Txbox.Transactions.Tx{}, ...]
  """
  def list_txs(filters \\ %{}) do
    Transactions.list(filters)
  end

  @doc """
  Searches transactions using full-text search.

  ## Examples

      iex> Bitblocks.Outbound.search_txs("invoice payment")
      [%Txbox.Transactions.Tx{}, ...]
  """
  def search_txs(query) do
    Transactions.search(query)
  end

  @doc """
  Updates transaction metadata or data.

  ## Examples

      iex> Bitblocks.Outbound.update_tx(tx, %{meta: %{status: "completed"}})
      {:ok, %Txbox.Transactions.Tx{}}
  """
  def update_tx(tx, attrs) do
    Transactions.update(tx, attrs)
  end

  @doc """
  Cancels a queued transaction (if not yet broadcasted).

  ## Examples

      iex> Bitblocks.Outbound.cancel_tx(tx)
      {:ok, %Txbox.Transactions.Tx{}}
  """
  def cancel_tx(tx) do
    result = Transactions.cancel(tx)

    case result do
      {:ok, cancelled_tx} ->
        broadcast_event("outbound_txs", {:tx_cancelled, cancelled_tx})
        broadcast_channel_event(cancelled_tx.channel, {:tx_cancelled, cancelled_tx})
        {:ok, cancelled_tx}

      error ->
        error
    end
  end

  # Private helpers

  defp broadcast_event(topic, event) do
    PubSub.broadcast(@pubsub, topic, event)
  end

  defp broadcast_channel_event(nil, _event), do: :ok

  defp broadcast_channel_event(channel, event) do
    PubSub.broadcast(@pubsub, "outbound_txs:#{channel}", event)
  end
end
