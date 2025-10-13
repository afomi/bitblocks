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

  alias Txbox.Transactions
  alias Txbox.Transactions.Tx
  alias Txbox.Mapi.Queue
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
    result = Transactions.create_tx(attrs)

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
  def build_tx(tx, _inputs, _outputs) do
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
  def sign_tx(tx, _private_keys) do
    # This would integrate with BSV library to sign the transaction
    # For now, this is a placeholder that returns the transaction unchanged
    broadcast_event("outbound_txs", {:tx_signed, tx})
    broadcast_channel_event(tx.channel, {:tx_signed, tx})
    {:ok, tx}
  end

  @doc """
  Queues a transaction for broadcasting via mAPI.

  The transaction will be automatically submitted to configured miners
  and tracked through the confirmation process.

  ## Examples

      iex> Bitblocks.Outbound.queue_tx(tx)
      {:ok, %Txbox.Transactions.Tx{}}
  """
  def queue_tx(%Tx{} = tx) do
    case Queue.push(tx) do
      :ok ->
        broadcast_event("outbound_txs", {:tx_queued, tx})
        broadcast_channel_event(tx.channel, {:tx_queued, tx})
        {:ok, tx}

      {:ok, %Txbox.Transactions.Tx{} = queued_tx} ->
        broadcast_event("outbound_txs", {:tx_queued, queued_tx})
        broadcast_channel_event(queued_tx.channel, {:tx_queued, queued_tx})
        {:ok, queued_tx}

      error ->
        broadcast_event("outbound_txs", {:tx_error, tx, error})
        broadcast_channel_event(tx.channel, {:tx_error, tx, error})
        error
    end
  end

  def queue_tx(id_or_txid) when is_binary(id_or_txid) do
    case Transactions.get_tx(id_or_txid) do
      nil ->
        {:error, :not_found}

      tx ->
        queue_tx(tx)
    end
  end

  def queue_tx(other), do: {:error, {:unsupported_tx_reference, other}}

  @doc """
  Gets a transaction by ID or txid.

  ## Examples

      iex> Bitblocks.Outbound.get_tx(id)
      %Txbox.Transactions.Tx{}

      iex> Bitblocks.Outbound.get_tx("txid_here")
      %Txbox.Transactions.Tx{}
  """
  def get_tx(id_or_txid) do
    Transactions.get_tx(id_or_txid)
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
    Transactions.list_tx(filters)
  end

  @doc """
  Searches transactions using full-text search.

  ## Examples

      iex> Bitblocks.Outbound.search_txs("invoice payment")
      [%Txbox.Transactions.Tx{}, ...]
  """
  def search_txs(query) do
    Transactions.search_tx(query)
  end

  @doc """
  Updates transaction metadata or data.

  ## Examples

      iex> Bitblocks.Outbound.update_tx(tx, %{meta: %{status: "completed"}})
      {:ok, %Txbox.Transactions.Tx{}}
  """
  def update_tx(tx, attrs) do
    Transactions.update_tx(tx, attrs)
  end

  @doc """
  Cancels a queued transaction (if not yet broadcasted).

  ## Examples

      iex> Bitblocks.Outbound.cancel_tx(tx)
      {:error, :not_implemented}
  """
  def cancel_tx(_tx) do
    # Txbox.Transactions.cancel/1 doesn't exist yet
    # This is a placeholder for future implementation
    {:error, :not_implemented}
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
