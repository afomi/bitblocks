defmodule Bitblocks.HodLocker do
  @moduledoc """
  HodLocker (#75): a social app (hodlocker.com, 2023 to 2024) where a post or
  a like is backed by sats in a time lock (`Bitblocks.TimeLock`).

  The shapes, read from real txs and from the app's source
  (github.com/zer0dt/hodlocker, `deployPost.tsx`):

    * **Post**: a time lock output, then a B record with the text, piped to
      MAP `SET app hodlocker.com type post paymail <paymail>`. The lock
      backs the post itself.
    * **Reply**: a post whose MAP also says `context tx tx <txid>`, the post
      it answers.
    * **Like**: a time lock output, then MAP
      `SET app hodlocker.com type like tx <txid>`. The lock backs the post
      named by `tx`.

  `parse/2` answers what a tx's locks back. A tx with no HodLocker MAP
  record is `nil`.
  """

  alias Bitblocks.{MapParser, TimeLock}

  @app "hodlocker.com"

  @type lock :: %{
          vout: non_neg_integer(),
          satoshis: non_neg_integer(),
          owner: String.t(),
          unlock_height: non_neg_integer()
        }

  @type t :: %{
          kind: :post | :reply | :like,
          post_txid: String.t(),
          reply_to: String.t() | nil,
          paymail: String.t() | nil,
          locks: [lock()]
        }

  @doc "The app name HodLocker writes in MAP's `app` field."
  def app, do: @app

  @doc """
  What a tx's time locks back: the post, and each lock's amount, owner and
  unlock height. `txid` is the tx's own id, which a post's locks back.
  """
  @spec parse(BSV.Tx.t(), String.t()) :: t() | nil
  def parse(%BSV.Tx{outputs: outputs}, txid) when is_binary(txid) do
    with %{} = keys <- record(outputs),
         {kind, post_txid} when is_binary(post_txid) <- kind(keys, txid) do
      %{
        kind: kind,
        post_txid: post_txid,
        reply_to: if(kind == :reply, do: keys["tx"]),
        paymail: keys["paymail"],
        locks: locks(outputs)
      }
    else
      _ -> nil
    end
  end

  def parse(_tx, _txid), do: nil

  @doc "True when the chunks of a data output carry a HodLocker MAP record."
  @spec record?([BSV.Script.chunk()]) :: boolean()
  def record?(chunks) when is_list(chunks), do: match?(%{}, map_keys(chunks))

  defp record(outputs) do
    Enum.find_value(outputs, fn %BSV.TxOut{script: %BSV.Script{chunks: chunks}} ->
      map_keys(chunks)
    end)
  end

  defp map_keys(chunks) do
    pushes = chunks |> data_pushes() |> Enum.filter(&is_binary/1)

    case pushes != [] && MapParser.parse(pushes) do
      {:ok, %{action: :set, app: @app, keys: keys}} -> keys
      _ -> nil
    end
  end

  defp data_pushes([:OP_FALSE, :OP_RETURN | rest]), do: rest
  defp data_pushes([:OP_RETURN | rest]), do: rest
  defp data_pushes(_), do: []

  defp kind(%{"type" => "like", "tx" => post}, _txid), do: {:like, txid_or_nil(post)}

  defp kind(%{"type" => "post", "context" => "tx", "tx" => parent} = _keys, txid),
    do: if(txid_or_nil(parent), do: {:reply, txid}, else: {:post, txid})

  defp kind(%{"type" => "post"}, txid), do: {:post, txid}
  defp kind(_keys, _txid), do: nil

  defp txid_or_nil(<<_::binary-64>> = txid) do
    if txid =~ ~r/\A[0-9a-f]{64}\z/, do: txid
  end

  defp txid_or_nil(_), do: nil

  defp locks(outputs) do
    for {%BSV.TxOut{script: script, satoshis: sats}, vout} <- Enum.with_index(outputs),
        {:ok, lock} <- [TimeLock.parse(script)] do
      %{vout: vout, satoshis: sats, owner: lock.owner, unlock_height: lock.unlock_height}
    end
  end
end
