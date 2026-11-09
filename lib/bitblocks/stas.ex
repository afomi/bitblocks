defmodule Bitblocks.Stas do
  @moduledoc """
  Reads a STAS token output (#78): the `stas` type in
  `priv/data/tx_types/types.json`.

  A STAS locking script is three parts, byte for byte:

      76 a9 14 <owner pubkey hash, 20> 88 ac      a P2PKH lock: who holds it
      <contract, 1,384 bytes>                     the same in every output
      6a 14 <redemption pubkey hash, 20>          OP_RETURN, the token's id
      <flags> <symbol and data ...>               pushes the issuer wrote

  The contract is matched by its sha256, so the classifier types every STAS
  output however many pushes follow the redemption hash (a template hash
  would count them). It is stas-js's `stasV2` script (TAAL, stas-js 3.0.3),
  the only STAS contract seen on chain so far: every token WhatsOnChain
  lists, issued from block 706,487 (September 2021), uses it. Another STAS
  version is a new contract hash here, from a real output.

  A flag of `00` means the token may be split, `01` that it may not
  (stas-js `isSplittable/1`). stas-js reads the push after the flags as the
  symbol; the tokens on chain mostly put free text there ("Token") or JSON,
  and the symbol WhatsOnChain shows comes from the issuer's contract tx, so
  this module calls those pushes `data` and says no more about them.

  Each satoshi is one unit of the token, so the amount is the output's value.
  """

  @contract_size 1_384

  # sha256 of the 1,384 contract bytes between the owner's P2PKH lock and the
  # OP_RETURN, read from chain_vectors.json's chain_stas (output 0 of
  # 0f9e2366…54a8, block 707,635).
  @contract_hashes MapSet.new([
                     "7f0a3e477955a1d7a62f0f3eff1b1b0fc60c0b76d102a3dc9629bd6f81f75ae9"
                   ])

  @type t :: %{
          owner_pkh: String.t(),
          owner: String.t(),
          token_id: String.t(),
          redemption_pkh: String.t(),
          splittable: boolean() | nil,
          flags: String.t() | nil,
          data: [binary()]
        }

  @doc """
  The token in a STAS output, or `:error` when the script isn't one.

  `token_id` is the redemption address (base58 of the redemption pubkey
  hash), as WhatsOnChain and stas-js name a token; `owner` is the holder's
  address.
  """
  @spec parse(BSV.Script.t() | binary()) :: {:ok, t()} | :error
  def parse(%BSV.Script{} = script), do: script |> BSV.Script.to_binary() |> parse()

  def parse(
        <<0x76, 0xA9, 0x14, owner::binary-20, 0x88, 0xAC, contract::binary-@contract_size, 0x6A,
          0x14, redemption::binary-20, tail::binary>>
      ) do
    with true <- contract?(contract),
         {:ok, pushes} <- pushes(tail) do
      {flags, data} =
        case pushes do
          [flags | data] -> {flags, data}
          [] -> {nil, []}
        end

      {:ok,
       %{
         owner_pkh: Base.encode16(owner, case: :lower),
         owner: address(owner),
         token_id: address(redemption),
         redemption_pkh: Base.encode16(redemption, case: :lower),
         splittable: splittable(flags),
         flags: flags && Base.encode16(flags, case: :lower),
         data: data
       }}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc "True when the script is a STAS output."
  @spec stas?(BSV.Script.t()) :: boolean()
  def stas?(
        %BSV.Script{
          chunks: [
            :OP_DUP,
            :OP_HASH160,
            <<_::binary-20>>,
            :OP_EQUALVERIFY,
            :OP_CHECKSIG,
            :OP_VERIFY | _
          ]
        } = script
      ),
      do: match?({:ok, _}, parse(script))

  def stas?(_script), do: false

  @doc """
  A data push as text when it is printable UTF-8, else as hex.
  """
  @spec data_text(binary()) :: String.t()
  def data_text(data) when is_binary(data) do
    if String.printable?(data), do: data, else: Base.encode16(data, case: :lower)
  end

  defp contract?(contract),
    do:
      MapSet.member?(
        @contract_hashes,
        Base.encode16(:crypto.hash(:sha256, contract), case: :lower)
      )

  defp splittable(<<0>>), do: true
  defp splittable(<<1>>), do: false
  defp splittable(_), do: nil

  defp address(pkh), do: %BSV.Address{pubkey_hash: pkh} |> BSV.Address.to_string()

  # The pushes after the redemption hash. Anything that isn't a push ends
  # the read: what came before it still counts.
  defp pushes(bytes, acc \\ [])
  defp pushes(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp pushes(<<0x00, rest::binary>>, acc), do: pushes(rest, ["" | acc])

  defp pushes(<<n, data::binary-size(n), rest::binary>>, acc) when n in 1..75,
    do: pushes(rest, [data | acc])

  defp pushes(<<0x4C, n, data::binary-size(n), rest::binary>>, acc),
    do: pushes(rest, [data | acc])

  defp pushes(<<0x4D, n::little-16, data::binary-size(n), rest::binary>>, acc),
    do: pushes(rest, [data | acc])

  defp pushes(<<0x4E, n::little-32, data::binary-size(n), rest::binary>>, acc),
    do: pushes(rest, [data | acc])

  defp pushes(_other, acc), do: {:ok, Enum.reverse(acc)}
end
