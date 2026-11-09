defmodule Bitblocks.Woc.AddressHistory do
  @moduledoc """
  An address's confirmed transactions in blocks the sync hasn't reached yet,
  read from WhatsOnChain (`Bitblocks.Woc`).

  Our index answers through `Sync.complete_through/0`; this answers above
  it, so a reader sees a payment soon after it confirms rather than when
  the sync climbs to its block. Two readers share it: the donation totals
  (`Bitblocks.Support.Recent`, #74) and address history
  (`Bitblocks.Chain.AddressHistory`, #80).

  `above/2` reads the address's confirmed history, keeps the entries above
  a height, and fetches those transactions (getrawtransaction-style maps
  with `hex`, `vin` and `vout`). Bounded: at most 5 history pages and 500
  transactions above the height; more is an error, never a silent partial
  list.

  Results are cached in ETS for 5 minutes (an error for 1), keyed by
  address and height, because the routes that read it are open or cheap to
  call and each miss costs WhatsOnChain several requests. The fetch runs in
  the caller, so a test's `Bitblocks.WocStub` answers it. This process only
  owns the table.
  """

  use GenServer

  require Logger

  alias Bitblocks.Woc

  @table __MODULE__
  @max_pages 5
  @max_txs 500
  @ok_ttl :timer.minutes(5)
  @error_ttl :timer.minutes(1)

  @type entry :: %{txid: String.t(), height: non_neg_integer(), tx: map()}
  @type result ::
          {:ok, %{txs: [entry()], through_height: non_neg_integer() | nil}}
          | {:error, term()}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The most transactions above the height `above/2` will fetch before it errs."
  def max_txs, do: @max_txs

  @doc """
  The confirmed transactions touching `address` in blocks above `height`,
  each with its txid, height and WhatsOnChain's tx map, and the
  WhatsOnChain tip they reach (nil when WoC didn't say).
  """
  @spec above(String.t(), integer()) :: result()
  def above(address, height) do
    key = {address, height}
    now = System.monotonic_time(:millisecond)

    case lookup(key) do
      {:ok, {expires, result}} when expires > now ->
        result

      _ ->
        result = fetch(address, height)
        ttl = if match?({:ok, _}, result), do: @ok_ttl, else: @error_ttl
        store(key, {now + ttl, result})
        result
    end
  end

  @doc "Forgets every cached result."
  def clear do
    :ets.delete_all_objects(@table)
  rescue
    ArgumentError -> true
  end

  defp fetch(address, height) do
    with {:ok, entries} <- history(address, nil, @max_pages, []),
         recent =
           entries
           |> Enum.filter(&(is_integer(&1.height) and &1.height > height))
           |> Enum.uniq_by(& &1.txid),
         :ok <- within_bound(recent),
         {:ok, txs} <- txs(Enum.map(recent, & &1.txid)) do
      tx_of = Map.new(txs, &{&1["txid"], &1})

      {:ok,
       %{
         txs: for(e <- recent, tx = tx_of[e.txid], do: %{txid: e.txid, height: e.height, tx: tx}),
         through_height: tip()
       }}
    else
      {:error, reason} = error ->
        Logger.warning("Woc.AddressHistory: #{address} above #{height}: #{inspect(reason)}")
        error
    end
  end

  defp history(_address, _token, 0, _acc), do: {:error, :too_many_pages}

  defp history(address, token, pages_left, acc) do
    case Woc.address_history(address, token) do
      {:ok, %{history: page, next_token: nil}} ->
        {:ok, Enum.concat(Enum.reverse([page | acc]))}

      {:ok, %{history: page, next_token: next}} ->
        history(address, next, pages_left - 1, [page | acc])

      {:error, _} = error ->
        error
    end
  end

  defp within_bound(recent) when length(recent) > @max_txs, do: {:error, :too_many_txs}
  defp within_bound(_recent), do: :ok

  defp txs(txids) do
    txids
    |> Enum.chunk_every(Woc.bulk_size())
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case Woc.txs(chunk) do
        {:ok, txs} when length(txs) == length(chunk) -> {:cont, {:ok, acc ++ txs}}
        {:ok, _short} -> {:halt, {:error, :txs_missing}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp tip do
    case Woc.chain_tip() do
      {:ok, height} -> height
      _ -> nil
    end
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, entry}] -> {:ok, entry}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp store(key, entry) do
    :ets.insert(@table, {key, entry})
  rescue
    ArgumentError -> true
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
