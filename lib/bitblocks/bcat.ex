defmodule Bitblocks.Bcat do
  @moduledoc """
  Reassembles a BCat file from its head transaction (#15).

  A head's OP_RETURN is `<15DHFx...> <info> <mime> <charset> <filename> <flag>`
  followed by the chunk txids, 32 bytes each, in file order. A chunk's is
  `<1ChDHz...> <data>`. The older `<15DHFx...> "c" <data>` shape that
  `TransactionLive.Show` recognises is read too.

  The head commits to its chunks by txid, and each chunk's bytes must hash to
  that txid, so a file assembled here is the file the head names. Nothing is
  partial: one chunk short is `{:error, {:missing, txids}}`, naming them.

  Chunks come from `TxStore`, then WhatsOnChain in bulk, kept in the blob store
  like any tx `/content` fetches. A txid push is read as written, and reversed
  if the first chunk isn't found that way, since no real head has been checked
  against this reader yet.

  `@max_chunks` and `@max_bytes` bound what one request can load.
  """

  require Logger

  alias Bitblocks.Chain.RawTx
  alias Bitblocks.Script.OpReturn
  alias Bitblocks.{TxStore, Woc}

  @head_prefix "15DHFxWZJT58f9nhyCA3mREYYzkVDetm6A"
  @part_prefix "1ChDHzdd1H4wSjgGMHyndZm6qxEDGjqpJL"

  @max_chunks 256
  @max_bytes 32 * 1024 * 1024

  @type head :: %{
          info: String.t() | nil,
          mime: String.t() | nil,
          charset: String.t() | nil,
          filename: String.t() | nil,
          flag: String.t() | nil,
          chunk_txids: [String.t()]
        }

  @doc """
  The assembled file: `{:ok, %{data:, mime:, charset:, filename:, chunks:}}`.

  Errors: `:not_found` (no such tx), `:not_bcat`, `:no_chunks`, `:too_large`,
  `{:missing, txids}` (no source has them), `{:unavailable, txids}` (a source
  couldn't be asked), `{:fetch_failed, reason}` (for the head itself).
  """
  @spec assemble(String.t()) :: {:ok, map()} | {:error, term()}
  def assemble(txid) when is_binary(txid) do
    with {:ok, bytes} <- head_bytes(txid),
         {:ok, %{chunk_txids: [_ | _]} = head} <- parse_head(bytes),
         true <- length(head.chunk_txids) <= @max_chunks || {:error, :too_large},
         {:ok, order, found, failed?} <- chunks(head.chunk_txids),
         {:ok, data} <- join(order, found, failed?) do
      {:ok,
       %{
         data: data,
         mime: head.mime,
         charset: head.charset,
         filename: head.filename,
         chunks: length(order)
       }}
    else
      {:ok, %{chunk_txids: []}} -> {:error, :no_chunks}
      {:error, _} = error -> error
    end
  end

  @doc "Reads a raw tx as a BCat head: `{:ok, head}` or `{:error, :not_bcat}`."
  @spec parse_head(binary()) :: {:ok, head()} | {:error, :not_bcat}
  def parse_head(bytes) do
    with {:ok, tx} <- bytes |> Base.encode16() |> RawTx.parse(),
         [info, mime, charset, filename, flag | pushes] <-
           Enum.find_value(tx.outputs, &head_fields/1) do
      {:ok,
       %{
         info: text(info),
         mime: text(mime),
         charset: text(charset),
         filename: text(filename),
         flag: text(flag),
         chunk_txids:
           for(
             <<push::binary-size(32)>> <- pushes,
             do: Base.encode16(push, case: :lower)
           )
       }}
    else
      _ -> {:error, :not_bcat}
    end
  end

  defp head_fields(output) do
    case OpReturn.raw_chunks(output.script) do
      [@head_prefix, "c" | _] -> nil
      [@head_prefix | fields] -> fields
      _ -> nil
    end
  end

  @doc "The data a raw chunk tx carries: `{:ok, data}` or `:error`."
  @spec chunk_data(binary()) :: {:ok, binary()} | :error
  def chunk_data(bytes) do
    with {:ok, tx} <- bytes |> Base.encode16() |> RawTx.parse(),
         data when is_binary(data) <- Enum.find_value(tx.outputs, &part/1) do
      {:ok, data}
    else
      _ -> :error
    end
  end

  defp part(output) do
    case OpReturn.raw_chunks(output.script) do
      [@part_prefix, data | _] when is_binary(data) -> data
      [@head_prefix, "c", data | _] when is_binary(data) -> data
      _ -> nil
    end
  end

  # An unset field is a space, a zero byte, or an empty push.
  defp text(value) when value in ["", " ", <<0>>], do: nil

  defp text(value) when is_binary(value) do
    if String.valid?(value), do: value
  end

  defp text(_opcode), do: nil

  defp head_bytes(txid) do
    case load([txid]) do
      {:ok, %{^txid => bytes}, _failed?} -> {:ok, bytes}
      {:ok, _none, true} -> {:error, {:fetch_failed, :woc}}
      {:ok, _none, false} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp chunks([first | _] = txids) do
    with {:ok, found, failed?} <- load(txids) do
      if Map.has_key?(found, first) or failed? do
        {:ok, txids, found, failed?}
      else
        reversed = Enum.map(txids, &reverse_hex/1)

        with {:ok, again, failed_again?} <- load(reversed) do
          if map_size(again) > 0,
            do: {:ok, reversed, again, failed_again?},
            else: {:ok, txids, found, failed?}
        end
      end
    end
  end

  defp join(order, found, failed?) do
    case Enum.reject(order, &Map.has_key?(found, &1)) do
      [] ->
        parts = Enum.map(order, &chunk_data(Map.fetch!(found, &1)))
        bad = for {txid, :error} <- Enum.zip(order, parts), do: txid

        if bad == [] do
          {:ok, IO.iodata_to_binary(for {:ok, data} <- parts, do: data)}
        else
          {:error, {:missing, bad}}
        end

      absent when failed? ->
        {:error, {:unavailable, absent}}

      absent ->
        {:error, {:missing, absent}}
    end
  end

  # Holds `txids` by txid, batch by batch, stopping past the byte budget.
  defp load(txids) do
    txids
    |> Enum.uniq()
    |> Enum.chunk_every(Woc.bulk_size())
    |> Enum.reduce_while({:ok, %{}, false}, fn batch, {:ok, found, failed?} ->
      {batch_found, batch_failed?} = load_batch(batch)
      found = Map.merge(found, batch_found)
      failed? = failed? or batch_failed?

      if total(found) > @max_bytes,
        do: {:halt, {:error, :too_large}},
        else: {:cont, {:ok, found, failed?}}
    end)
  end

  defp total(found), do: found |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

  defp load_batch(batch) do
    held =
      for txid <- batch,
          {:ok, bytes} <- [TxStore.raw(txid)],
          TxStore.txid(bytes) == txid,
          into: %{},
          do: {txid, bytes}

    case batch -- Map.keys(held) do
      [] ->
        {held, false}

      absent ->
        case Woc.txs(absent) do
          {:ok, txs} ->
            {Map.merge(held, verified(txs, absent)), false}

          {:error, reason} ->
            Logger.warning("bcat: WhatsOnChain unavailable: #{inspect(reason)}")
            {held, true}
        end
    end
  end

  defp verified(txs, asked) do
    for %{"hex" => hex} <- txs,
        {:ok, bytes} <- [Base.decode16(hex, case: :mixed)],
        txid = TxStore.txid(bytes),
        txid in asked,
        into: %{} do
      case TxStore.put(txid, bytes) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("bcat: not cached #{txid}: #{inspect(reason)}")
      end

      {txid, bytes}
    end
  end

  defp reverse_hex(hex) do
    hex
    |> Base.decode16!(case: :lower)
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> :binary.list_to_bin()
    |> Base.encode16(case: :lower)
  end
end
