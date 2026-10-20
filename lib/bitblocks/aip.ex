defmodule Bitblocks.Aip do
  @moduledoc """
  Verifies Author Identity Protocol (AIP) signatures in Bitcom OP_RETURN data.

  Spec: https://github.com/attilaaf/AUTHOR_IDENTITY_PROTOCOL (Attila Aros).
  The read-side twin of qart's `Qart.Protocol.AIP` — the message rule must stay
  identical so receipts qart signs verify here (see `test/bitblocks/aip_test.exs`,
  which carries qart's recorded `@1sat/actions` vector).

  ## Wire format

      OP_FALSE OP_RETURN
        <fields…>
        |
        15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva   # AIP prefix
        BITCOIN_ECDSA                        # signing algorithm
        <signing address>
        <signature>                          # Bitcoin Signed Message
        [<field index>…]                     # optional

  ## What is signed

  Without field indexes, every field to the left of the AIP prefix, where
  field 0 is the `OP_RETURN` opcode byte (`0x6a`) and the `|` just before the
  prefix is included:

      message = <<0x6a>> <> field_1 <> … <> field_n <> "|"

  `OP_FALSE` is not part of the message. With field indexes, only the listed
  fields (same numbering, 0 = `0x6a`) are concatenated, in index order.

  The signature may be base64 text (the spec) or a raw 65-byte compact
  signature (`@1sat/templates`).
  """

  require Logger

  alias BSV.{Address, Message}

  @prefix "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva"
  @algorithm "BITCOIN_ECDSA"
  @op_return <<0x6A>>

  @type signature :: %{
          address: String.t() | nil,
          algorithm: String.t() | nil,
          field_indexes: [non_neg_integer()] | nil,
          valid: boolean()
        }

  @doc "The AIP Bitcom prefix."
  def prefix, do: @prefix

  @doc """
  Checks every AIP section in an OP_RETURN data list.

  `data` is the list of pushes as binaries; leading `OP_FALSE` / `OP_RETURN`
  atoms are skipped. Each AIP section is checked against all fields to its left.
  Returns one `t:signature/0` per section, in order, or `[]` when there is none.
  """
  @spec signatures(list()) :: [signature()]
  def signatures(data) when is_list(data) do
    data = strip_opcodes(data)

    data
    |> Enum.with_index()
    |> Enum.filter(fn {cell, _i} -> cell == @prefix end)
    |> Enum.map(fn {_cell, i} -> check(Enum.take(data, i), Enum.drop(data, i + 1)) end)
  end

  @doc """
  Verifies the first AIP signature in `data`.

  Returns `{:ok, address}`, `{:error, :invalid_signature}`, or
  `{:error, :no_aip}`.
  """
  @spec verify(list()) :: {:ok, String.t()} | {:error, :invalid_signature | :no_aip}
  def verify(data) when is_list(data) do
    case signatures(data) do
      [%{valid: true, address: address} | _] -> {:ok, address}
      [_ | _] -> {:error, :invalid_signature}
      [] -> {:error, :no_aip}
    end
  end

  @doc "The deduplicated addresses of every valid AIP signature in `data`."
  @spec verified_signers(list()) :: [String.t()]
  def verified_signers(data) when is_list(data) do
    data
    |> signatures()
    |> Enum.filter(& &1.valid)
    |> Enum.map(& &1.address)
    |> Enum.uniq()
  end

  # `left` is everything before the AIP prefix (it should end with "|").
  defp check(left, [algorithm, address, signature | indexes])
       when is_binary(algorithm) and is_binary(address) and is_binary(signature) do
    field_indexes = parse_indexes(indexes)

    %{
      address: address,
      algorithm: algorithm,
      field_indexes: field_indexes,
      valid:
        algorithm == @algorithm and
          valid_signature?(signed_bytes(left, field_indexes), address, signature)
    }
  end

  defp check(_left, _malformed),
    do: %{address: nil, algorithm: nil, field_indexes: nil, valid: false}

  defp signed_bytes(left, nil), do: IO.iodata_to_binary([@op_return | binaries(left)])

  defp signed_bytes(left, indexes) do
    fields = List.to_tuple([@op_return | binaries(left)])

    indexes
    |> Enum.map(fn i -> if i < tuple_size(fields), do: elem(fields, i), else: "" end)
    |> IO.iodata_to_binary()
  end

  # Opcodes inside the signed region can't be represented as field bytes.
  defp binaries(cells), do: Enum.map(cells, fn c -> if is_binary(c), do: c, else: "" end)

  defp valid_signature?(message, address, signature) do
    with {:ok, address} <- parse_address(address),
         {:ok, encoding} <- signature_encoding(signature) do
      Message.verify(signature, message, address, encoding: encoding) == true
    else
      _ -> false
    end
  rescue
    e ->
      Logger.debug("Aip: signature check raised #{inspect(e.__struct__)}")
      false
  end

  # A 65-byte binary is a raw compact signature (@1sat/templates); anything
  # else must be base64 text (the spec).
  defp signature_encoding(sig) when byte_size(sig) == 65, do: {:ok, :raw}

  defp signature_encoding(sig) do
    case Base.decode64(sig) do
      {:ok, <<_::binary-size(65)>>} -> {:ok, :base64}
      _ -> :error
    end
  end

  # Signers may be on either network; the signature binds the pubkey hash.
  # (bsv 2.1's Address.from_string/1 only accepts the configured network.)
  defp parse_address(address) do
    case B58.decode58_check(address) do
      {:ok, {<<pubkey_hash::binary-20>>, version}} when version in [<<0x00>>, <<0x6F>>] ->
        {:ok, %Address{pubkey_hash: pubkey_hash}}

      _ ->
        :error
    end
  end

  defp parse_indexes([]), do: nil

  # The spec's example writes each index as a raw byte (0x00, 0x01, …);
  # @1sat/templates writes decimal text ("0", "1", …). Accept both.
  defp parse_indexes(cells) do
    Enum.flat_map(cells, fn
      <<byte>> when byte not in ?0..?9 ->
        [byte]

      cell when is_binary(cell) ->
        case Integer.parse(cell) do
          {i, ""} when i >= 0 -> [i]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp strip_opcodes(data) do
    Enum.drop_while(data, &(&1 in [:OP_FALSE, :OP_0, :OP_RETURN]))
  end
end
