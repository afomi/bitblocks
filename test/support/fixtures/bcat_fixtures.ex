defmodule Bitblocks.BcatFixtures do
  @moduledoc """
  BCat txs built to the BCat layout with real txids (`Bitblocks.Bcat`): a
  head naming its chunks, and chunks carrying the file's bytes. Each is
  `{txid, hex}`.
  """

  alias Bitblocks.TxStore

  @head "15DHFxWZJT58f9nhyGnsRBqrgwK4W6h4Up"
  @part "1ChDHzdd1H4wSjgGMHyndZm6qxEDGjqpJL"

  @doc "A tx with one OP_FALSE OP_RETURN output of these pushes."
  def tx(pushes) do
    script = IO.iodata_to_binary([<<0, 0x6A>> | Enum.map(pushes, &push/1)])

    bytes =
      <<1::little-32, 1, :rand.uniform(1_000_000)::size(256), 0::32, 0, 0xFFFFFFFF::32, 1, 0::64>> <>
        varint(byte_size(script)) <> script <> <<0::32>>

    {TxStore.txid(bytes), Base.encode16(bytes, case: :lower)}
  end

  @doc "A chunk tx carrying `data`."
  def chunk(data), do: tx([@part, data])

  @doc "A head naming `chunks` in order; `mime:`, `charset:` and `filename:` override."
  def head(chunks, opts \\ []) do
    ids = for {txid, _hex} <- chunks, do: Base.decode16!(txid, case: :lower)

    tx(
      [
        @head,
        " ",
        opts[:mime] || "text/plain",
        opts[:charset] || "utf-8",
        opts[:filename] || "a file.txt",
        " "
      ] ++ ids
    )
  end

  defp push(data) when byte_size(data) < 76, do: <<byte_size(data), data::binary>>
  defp push(data) when byte_size(data) < 256, do: <<76, byte_size(data), data::binary>>
  defp push(data), do: <<78, byte_size(data)::little-32, data::binary>>

  defp varint(n) when n < 253, do: <<n>>
  defp varint(n) when n < 0x10000, do: <<253, n::little-16>>
  defp varint(n), do: <<254, n::little-32>>
end
