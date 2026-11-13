defmodule Bitblocks.Stas do
  @moduledoc """
  Reads a STAS token output (#78): the `stas` type in
  `priv/data/tx_types/types.json`.

  A STAS locking script is three parts, byte for byte:

      76 a9 14 <owner pubkey hash, 20> 88 ac      a P2PKH lock: who holds it
      <contract>                                  the same in every output of a version
      6a 14 <redemption pubkey hash, 20>          OP_RETURN, the token's id
      <flags> <symbol and data ...>               pushes the issuer wrote

  The contract is matched by its sha256, so the classifier types every STAS
  output however many pushes follow the redemption hash (a template hash
  would count them). Each version of STAS is its own contract, listed here
  from a real output:

    * `STAS`, 1,384 bytes: stas-js's `stasV2` script (TAAL, stas-js 3.0.3),
      the legacy template in the STAS SDK. Every token WhatsOnChain lists,
      issued from block 706,487 (September 2021), uses it.
    * `STAS-20`, 1,288 bytes: the STAS SDK's stablecoin template (stas-sdk,
      2023), divisible and redeemable only by the issuer. It writes no flags
      byte: the pushes after the redemption hash are the symbol and data.

  The SDK's other templates, STAS-789 (1,167 bytes) and STAS-50 (5,296
  bytes), join this list once a real output of each is found.

  A flag of `00` means the token may be split, `01` that it may not
  (stas-js `isSplittable/1`). stas-js reads the push after the flags as the
  symbol; the tokens on chain mostly put free text there ("Token") or JSON,
  and the symbol WhatsOnChain shows comes from the issuer's contract tx, so
  this module calls those pushes `data` and says no more about them.

  Each satoshi is one unit of the token, so the amount is the output's value.
  """

  # {contract size, sha256 of the contract bytes between the owner's P2PKH
  # lock and the OP_RETURN, version}, each read from a real output:
  #   STAS: chain_vectors.json's chain_stas (output 0 of 0f9e2366…54a8,
  #     block 707,635).
  #   STAS-20: chain_vectors.json's chain_stas20 (output 0 of 7b678504…c233,
  #     the STAS SDK's instantMint example issue).
  @contracts [
    {1_384, "7f0a3e477955a1d7a62f0f3eff1b1b0fc60c0b76d102a3dc9629bd6f81f75ae9", "STAS"},
    {1_288, "4f4ff46a908b909a7e913e31eafa65f6606615300a0e664f751596fddd2e743f", "STAS-20"}
  ]

  # Versions that write a flags byte ahead of the data.
  @flagged ["STAS"]

  # Versions that are always divisible, with no flag to say so.
  @divisible ["STAS-20"]

  @type t :: %{
          version: String.t(),
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

  `version` names the STAS contract (`STAS`, `STAS-20`). `token_id` is the
  redemption address (base58 of the redemption pubkey hash), as WhatsOnChain
  and stas-js name a token; `owner` is the holder's address.
  """
  @spec parse(BSV.Script.t() | binary()) :: {:ok, t()} | :error
  def parse(%BSV.Script{} = script), do: script |> BSV.Script.to_binary() |> parse()

  def parse(<<0x76, 0xA9, 0x14, owner::binary-20, 0x88, 0xAC, rest::binary>>) do
    with {version, redemption, tail} <- contract(rest),
         {:ok, pushes} <- pushes(tail) do
      {flags, data} = split_flags(version, pushes)

      {:ok,
       %{
         version: version,
         owner_pkh: Base.encode16(owner, case: :lower),
         owner: address(owner),
         token_id: address(redemption),
         redemption_pkh: Base.encode16(redemption, case: :lower),
         splittable: if(version in @divisible, do: true, else: splittable(flags)),
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

  # The version whose contract opens `bytes`, with the redemption hash and the
  # bytes after it, or nil.
  defp contract(bytes) do
    Enum.find_value(@contracts, fn {size, hash, version} ->
      case bytes do
        <<contract::binary-size(size), 0x6A, 0x14, redemption::binary-20, tail::binary>> ->
          if Base.encode16(:crypto.hash(:sha256, contract), case: :lower) == hash,
            do: {version, redemption, tail}

        _ ->
          nil
      end
    end)
  end

  defp split_flags(version, [flags | data]) when version in @flagged, do: {flags, data}
  defp split_flags(version, []) when version in @flagged, do: {nil, []}
  defp split_flags(_version, pushes), do: {nil, pushes}

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
