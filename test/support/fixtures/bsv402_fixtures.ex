defmodule Bitblocks.Bsv402Fixtures do
  @moduledoc """
  BRC-121 payments for tests and for `scripts/bsv402_vectors_v0.exs`: test
  keys made from fixed labels, and an Atomic BEEF paying one BRC-29 output,
  its coin alone in a one-tx block so the coin's txid is that block's root.

  Nothing here is signed: each input unlocks with a bare OP_0, so a real node
  would refuse these. A test stubs the node's answer.
  """

  alias Bitblocks.Chain.Beef
  alias Bitblocks.Interop.Brc42
  alias Bitblocks.Payments.Bsv402

  @label "bitblocks bsv402 vectors v0: "

  @doc "32 bytes from a label: the vectors' keys, coins and nonce."
  def label(text), do: :crypto.hash(:sha256, @label <> text)

  @doc "The server's test identity private key."
  def server_private, do: label("server")

  @doc "Another server's test identity public key."
  def other_server_public, do: Brc42.public_key(label("other server"))

  @doc "The payer's test identity private key."
  def sender_private, do: label("sender")

  @doc "The payer's test identity public key."
  def sender_public, do: Brc42.public_key(sender_private())

  @doc "The vectors' derivation prefix (x-bsv-nonce): 8 bytes, base64."
  def nonce, do: Base.encode64(binary_part(label("nonce"), 0, 8))

  @doc "The P2PKH locking script for a public key."
  def p2pkh(pub) do
    <<0x76, 0xA9, 0x14, :crypto.hash(:ripemd160, :crypto.hash(:sha256, pub))::binary, 0x88, 0xAC>>
  end

  @doc "The key the payer's wallet pays for `server_pub` at `time` (BRC-29)."
  def derived(server_pub, time) do
    {:ok, pub} = Brc42.public_child(sender_private(), server_pub, Bsv402.invoice(nonce(), time))
    pub
  end

  @doc "A tx with one input per `{prev_internal_hash, vout}` and the given `{sats, script}` outputs."
  def tx(inputs, outputs) do
    IO.iodata_to_binary([
      <<1::little-32>>,
      varint(length(inputs)),
      Enum.map(inputs, fn {prev, vout} ->
        [prev, <<vout::little-32>>, 1, 0, <<0xFFFFFFFF::little-32>>]
      end),
      varint(length(outputs)),
      Enum.map(outputs, fn {sats, script} ->
        [<<sats::little-64>>, varint(byte_size(script)), script]
      end),
      <<0::little-32>>
    ])
  end

  @doc "The payer's coin for `tag`: 100,000 sats to the sender, and any `extra` outputs."
  def coin(tag, extra \\ []),
    do: tx([{label("coin " <> tag), 0}], [{100_000, p2pkh(sender_public())} | extra])

  @doc """
  A payment of `price` (or `:sats`) from `coin`, mined alone at `height`.
  Options: `:time` (the x-bsv-time text), `:pay_to` (the server key the
  output is derived for), `:sats`, `:bump_height`, `:wrap` (`:atomic`,
  `:bare` or `:truncated`), `:header_time`, `:vout`, `:drop` (header names
  left out).

  `%{txid:, coin_root:, headers: [{name, value}], payment:}`, `coin_root`
  the display hex of the coin's txid, the root its block must hold.
  """
  def payment(coin, height, price, opts \\ []) do
    time = Keyword.fetch!(opts, :time)
    pay_to = Keyword.get(opts, :pay_to, Brc42.public_key(server_private()))
    sats = Keyword.get(opts, :sats, price)
    coin_hash = sha256d(coin)

    payment =
      tx([{coin_hash, 0}], [
        {sats, p2pkh(derived(pay_to, time))},
        {99_000 - price, p2pkh(sender_public())}
      ])

    txid = display(sha256d(payment))
    leaf = %{offset: 0, hash: coin_hash, txid: true, duplicate: false}

    beef =
      Beef.encode([%{height: Keyword.get(opts, :bump_height, height), path: [[leaf]]}], [
        {coin, 0},
        {payment, nil}
      ])

    bytes =
      case Keyword.get(opts, :wrap, :atomic) do
        :atomic -> Beef.atomic(beef, txid)
        :bare -> beef
        :truncated -> binary_part(Beef.atomic(beef, txid), 0, 60)
      end

    headers =
      Enum.reject(
        [
          {"x-bsv-beef", Base.encode64(bytes)},
          {"x-bsv-sender", hex(sender_public())},
          {"x-bsv-nonce", nonce()},
          {"x-bsv-time", Keyword.get(opts, :header_time, time)},
          {"x-bsv-vout", Keyword.get(opts, :vout, "0")}
        ],
        fn {name, _} -> name in Keyword.get(opts, :drop, []) end
      )

    %{txid: txid, coin_root: display(coin_hash), headers: headers, payment: payment}
  end

  @doc "Display hex of a hash in internal byte order."
  def display(hash),
    do: hash |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin() |> hex()

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))

  defp varint(n) when n < 0xFD, do: <<n>>
  defp varint(n) when n <= 0xFFFF, do: <<0xFD, n::little-16>>
  defp varint(n), do: <<0xFE, n::little-32>>
end
