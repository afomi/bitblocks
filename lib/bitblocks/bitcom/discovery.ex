defmodule Bitblocks.Bitcom.Discovery do
  @moduledoc """
  Historical Bitcom commands (#24): bitblocks only sees the txs it has fetched,
  so a `$ useradd`, `echo` or `route` in a block not synced yet is invisible.
  For a known address, this reads its history from WhatsOnChain, a page at a
  time, fetches the txs we don't hold, and logs any Bitcom commands they carry.

  A command speaks for the address that funded its tx, and its bytes are here,
  so each tx's bytes are hashed against its txid and the command is read
  exactly as it is at ingest. Only `bitcom_commands` is written, with the block
  height WhatsOnChain gives; no `transactions` row is added, so public history
  can't fill the database. When the sync reaches that block, ingest logs the
  same txid and output, which is a no-op.

  `scan_page/3` is one page, a dry run unless given `apply: true`.
  `Workers.BitcomDiscoveryWorker` walks the pages as Oban jobs.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.{Bitcom, Repo, TxStore, Woc}
  alias Bitblocks.Bitcom.Command
  alias Bitblocks.Chain.{SafeTx, Transaction}

  @type page :: %{
          address: String.t(),
          history: non_neg_integer(),
          fetched: non_neg_integer(),
          commands: non_neg_integer(),
          logged: non_neg_integer(),
          proofs: non_neg_integer(),
          next_token: String.t() | nil
        }

  @doc """
  Scans one page of `address`'s history, from `token` (nil for the first).
  Options: `apply: true` writes the commands found (default: dry run).
  """
  @spec scan_page(String.t(), String.t() | nil, keyword()) :: {:ok, page()} | {:error, term()}
  def scan_page(address, token \\ nil, opts \\ []) do
    apply? = Keyword.get(opts, :apply, false) == true

    with {:ok, %{history: history, next_token: next}} <- Woc.address_history(address, token),
         heights = Map.new(history, &{&1.txid, &1.height}),
         unseen = unseen(Map.keys(heights)),
         {:ok, txs} <- fetch(unseen) do
      found = Enum.flat_map(txs, &commands(&1, heights))

      {logged, proofs} =
        if apply?, do: write(txs, heights), else: {0, 0}

      {:ok,
       %{
         address: address,
         history: length(history),
         fetched: length(txs),
         commands: length(found),
         logged: logged,
         proofs: proofs,
         next_token: next
       }}
    end
  end

  # Txs ingest already saw, or a page already scanned, need no second fetch.
  defp unseen([]), do: []

  defp unseen(txids) do
    stored = Repo.all(from t in Transaction, where: t.txid in ^txids, select: t.txid)
    logged = Repo.all(from c in Command, where: c.txid in ^txids, select: c.txid)

    txids -- Enum.uniq(stored ++ logged)
  end

  defp fetch(txids) do
    txids
    |> Enum.chunk_every(Woc.bulk_size())
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case Woc.txs(batch) do
        {:ok, txs} -> {:cont, {:ok, verified(txs, batch) ++ acc}}
        {:error, reason} -> {:halt, {:error, {:fetch_failed, reason}}}
      end
    end)
  end

  defp verified(txs, asked) do
    for %{"hex" => hex} <- txs,
        {:ok, bytes} <- [Base.decode16(hex, case: :mixed)],
        txid = TxStore.txid(bytes),
        txid in asked do
      %{txid: txid, raw: String.downcase(hex)}
    end
  end

  defp commands(%{txid: txid, raw: raw}, heights) do
    case SafeTx.from_hex(raw) do
      {:ok, decoded} -> Bitcom.commands(decoded, txid: txid, block_height: heights[txid])
      {:error, _} -> []
    end
  end

  defp write(txs, heights) do
    Enum.reduce(txs, {0, 0}, fn %{txid: txid, raw: raw}, {logged, proofs} ->
      {:ok, result} =
        Bitcom.index(%{
          txid: txid,
          raw: raw,
          protocols: ["Bitcom"],
          block_height: heights[txid]
        })

      {logged + result.commands, proofs + result.proofs}
    end)
  end
end
