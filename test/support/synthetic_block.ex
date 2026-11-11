defmodule Bitblocks.SyntheticBlock do
  @moduledoc """
  A serialized block made up in the test, of any size: a header whose
  merkleroot is right for its txs, a coinbase, then txs of varied size, so a
  stream of it splits txs across chunks and every varint width appears (#66).

  The merkle root is built here level by level, independently of
  `Chain.MerkleBuilder`, so a test of the builder checks it against a second
  implementation.
  """

  @doc """
  `%{bytes: block, hash: display hash, merkleroot: display hex, txids: [...],
  largest_tx: n}` for a block of roughly `target_bytes`.

  Options:
    * `:pay_to` - a 20-byte pubkey hash; the second tx pays it
      `:pay_sats` (default 12_345) by P2PKH.
    * `:big_every` - every nth tx carries a 70 KB OP_RETURN (0xFE varint,
      several chunks wide); default 50.
    * `:big_tx_bytes` - one tx of this many bytes, as the third tx.
  """
  @spec build(pos_integer(), keyword()) :: map()
  def build(target_bytes, opts \\ []) do
    big_every = Keyword.get(opts, :big_every, 50)

    txs =
      [coinbase()] ++
        if(opts[:pay_to],
          do: [payment(opts[:pay_to], Keyword.get(opts, :pay_sats, 12_345))],
          else: []
        ) ++
        if(opts[:big_tx_bytes], do: [data_tx(opts[:big_tx_bytes] - 60)], else: [])

    txs =
      fill(
        Enum.reverse(txs),
        Enum.sum_by(txs, &byte_size/1),
        target_bytes,
        big_every,
        length(txs)
      )

    hashes = Enum.map(txs, &sha256d/1)
    root = merkle_root(hashes)

    header =
      <<1::little-32, :crypto.strong_rand_bytes(32)::binary, root::binary,
        1_700_000_000::little-32, 0x1D00FFFF::little-32, 7::little-32>>

    bytes = IO.iodata_to_binary([header, varint(length(txs)) | txs])

    %{
      bytes: bytes,
      hash: display(sha256d(header)),
      merkleroot: display(root),
      txids: Enum.map(hashes, &display/1),
      largest_tx: txs |> Enum.map(&byte_size/1) |> Enum.max()
    }
  end

  defp fill(txs, size, target, _big_every, _n) when size >= target, do: Enum.reverse(txs)

  defp fill(txs, size, target, big_every, n) do
    tx =
      if rem(n, big_every) == 0,
        do: data_tx(70_000),
        else: ordinary(rem(n * 37, 300))

    fill([tx | txs], size + byte_size(tx), target, big_every, n + 1)
  end

  defp coinbase do
    script = "synthetic coinbase " <> :crypto.strong_rand_bytes(8)

    tx(
      [{<<0::256>>, 0xFFFFFFFF, script}],
      [{625_000_000, p2pkh(:crypto.strong_rand_bytes(20))}]
    )
  end

  defp payment(pkh, sats) do
    tx([input(107)], [{sats, p2pkh(pkh)}, {1_000, p2pkh(:crypto.strong_rand_bytes(20))}])
  end

  # An ordinary spend: a signature-sized unlock and one or two outputs, plus
  # `extra` bytes of OP_RETURN data now and then (0xFD varints from 253).
  defp ordinary(extra) do
    outputs = [{5_000, p2pkh(:crypto.strong_rand_bytes(20))}]
    outputs = if extra > 0, do: outputs ++ [{0, op_return(extra)}], else: outputs
    tx([input(107)], outputs)
  end

  defp data_tx(data_bytes), do: tx([input(107)], [{0, op_return(data_bytes)}])

  defp input(script_bytes),
    do: {:crypto.strong_rand_bytes(32), 0, :crypto.strong_rand_bytes(script_bytes)}

  defp tx(inputs, outputs) do
    IO.iodata_to_binary([
      <<1::little-32>>,
      varint(length(inputs)),
      for(
        {prev, vout, script} <- inputs,
        do: [
          prev,
          <<vout::little-32>>,
          varint(byte_size(script)),
          script,
          <<0xFFFFFFFF::little-32>>
        ]
      ),
      varint(length(outputs)),
      for(
        {sats, script} <- outputs,
        do: [<<sats::little-64>>, varint(byte_size(script)), script]
      ),
      <<0::little-32>>
    ])
  end

  defp p2pkh(<<_::binary-20>> = pkh), do: <<0x76, 0xA9, 0x14, pkh::binary, 0x88, 0xAC>>
  defp op_return(n), do: <<0x00, 0x6A>> <> :binary.copy(<<0x42>>, n)

  @doc "Bitcoin's varint."
  def varint(n) when n < 0xFD, do: <<n>>
  def varint(n) when n <= 0xFFFF, do: <<0xFD, n::little-16>>
  def varint(n) when n <= 0xFFFFFFFF, do: <<0xFE, n::little-32>>
  def varint(n), do: <<0xFF, n::little-64>>

  @doc "The merkle root of internal-order hashes, level by level."
  def merkle_root([root]), do: root

  def merkle_root(level) do
    level
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [a, b] -> sha256d(a <> b)
      [a] -> sha256d(a <> a)
    end)
    |> merkle_root()
  end

  def sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))

  def display(hash),
    do:
      hash
      |> :binary.bin_to_list()
      |> Enum.reverse()
      |> :binary.list_to_bin()
      |> Base.encode16(case: :lower)
end
