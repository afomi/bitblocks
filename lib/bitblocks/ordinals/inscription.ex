defmodule Bitblocks.Ordinals.Inscription do
  @moduledoc """
  Reads a 1Sat ordinal inscription from an output's locking script.

      OP_FALSE OP_IF "ord"
        OP_1 <content-type>
        OP_3 <parent: txid, 32 bytes little-endian [+ vout, 4 bytes LE]>
        <"1PuQa7…" (MAP prefix)> <MAP: pushes "SET" k v k v …>
        OP_0 <content>
      OP_ENDIF
      <lock, e.g. P2PKH: the owner>

  The lock can as well come first, with the envelope after it: past a P2PKH the
  envelope is skipped data, so the output spends the same way. Real BSV-20
  outputs are built both ways.

  Fields may appear in any order. Numbered fields are keyed by number and
  others by their tag bytes, so unknown fields are kept rather than dropped
  (unlike `Bsv20Parser`, which reads only what BSV-20 needs).
  """

  @map_prefix "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"

  @type t :: %{
          content_type: String.t() | nil,
          content: binary() | nil,
          parent: String.t() | nil,
          map: map(),
          owner: String.t() | nil
        }

  @type lock :: %{
          type: String.t(),
          owner: String.t() | nil,
          cosigner: String.t() | nil
        }

  @doc "Parses an inscription from a script (binary or `%BSV.Script{}`)."
  @spec parse(binary() | BSV.Script.t()) :: {:ok, t()} | {:error, :no_inscription}
  def parse(%BSV.Script{chunks: chunks}), do: parse_chunks(chunks)

  def parse(script) when is_binary(script) do
    case BSV.Script.from_binary(script) do
      {:ok, %BSV.Script{chunks: chunks}} -> parse_chunks(chunks)
      _ -> {:error, :no_inscription}
    end
  end

  defp parse_chunks(chunks) do
    with {:ok, fields, _after_envelope} <- envelope(chunks) do
      {:ok,
       %{
         content_type: text(fields[1]),
         content: fields[0],
         parent: parent(fields[3]),
         map: decode_map(fields[@map_prefix]),
         owner: lock_owner(%BSV.Script{chunks: chunks})
       }}
    end
  end

  @doc """
  The P2PKH address locking an output, with an inscription before the lock,
  after it or not at all; nil for any other lock (e.g. a sale contract).
  """
  @spec lock_owner(BSV.Script.t()) :: String.t() | nil
  def lock_owner(%BSV.Script{} = script) do
    case lock(script) do
      %{type: "p2pkh", owner: owner} -> owner
      _ -> nil
    end
  end

  @doc """
  Who an output's lock answers to, read from the script either side of an
  inscription envelope:

    * `p2pkh`: `owner` is the address;
    * `cosign`: `owner` is the address that must sign, and `cosigner` the hex
      public key that must sign with it. The owner holds it: the cosigner can
      approve a spend and can't start one (`priv/data/tx_types/types.json`);
    * `other`: a contract or any other script, with no address to name.
  """
  @spec lock(BSV.Script.t()) :: lock()
  def lock(%BSV.Script{chunks: chunks}) do
    chunks
    |> lock_parts()
    |> Enum.find_value(%{type: "other", owner: nil, cosigner: nil}, &read_lock/1)
  end

  # The script after the envelope, then the script before it.
  defp lock_parts(chunks), do: lock_parts(chunks, [])

  defp lock_parts([marker, :OP_IF, "ord" | _] = rest, before)
       when marker in [:OP_FALSE, :OP_0] do
    case envelope(rest) do
      {:ok, _fields, after_envelope} -> [after_envelope, Enum.reverse(before)]
      _ -> [Enum.reverse(before) ++ rest]
    end
  end

  defp lock_parts([chunk | rest], before), do: lock_parts(rest, [chunk | before])
  defp lock_parts([], before), do: [Enum.reverse(before)]

  defp read_lock(chunks) do
    case {p2pkh_owner(chunks), cosign(chunks)} do
      {owner, _} when is_binary(owner) -> %{type: "p2pkh", owner: owner, cosigner: nil}
      {_, {owner, cosigner}} -> %{type: "cosign", owner: owner, cosigner: cosigner}
      _ -> nil
    end
  end

  # The cosign shape `TxTypes.Classifier` types, with the same OP_RETURN note
  # allowed after it as P2PKH.
  defp cosign([
         :OP_DUP,
         :OP_HASH160,
         <<pkh::binary-20>>,
         :OP_EQUALVERIFY,
         :OP_CHECKSIGVERIFY,
         <<cosigner::binary-33>>,
         :OP_CHECKSIG | rest
       ])
       when rest == [] or hd(rest) == :OP_RETURN do
    {BSV.Address.to_string(%BSV.Address{pubkey_hash: pkh}), Base.encode16(cosigner, case: :lower)}
  end

  defp cosign(_), do: nil

  defp envelope([marker, :OP_IF, "ord" | rest]) when marker in [:OP_FALSE, :OP_0],
    do: read_fields(rest, %{})

  defp envelope([_ | rest]), do: envelope(rest)
  defp envelope([]), do: {:error, :no_inscription}

  defp read_fields([:OP_ENDIF | rest], fields), do: {:ok, fields, rest}

  defp read_fields([tag, value | rest], fields) when is_binary(value),
    do: read_fields(rest, Map.put_new(fields, field_key(tag), value))

  defp read_fields([_ | rest], fields), do: read_fields(rest, fields)
  defp read_fields([], _fields), do: {:error, :no_inscription}

  defp field_key(op) when op in [:OP_0, :OP_FALSE], do: 0
  defp field_key(op) when op in [:OP_1, :OP_TRUE], do: 1

  defp field_key(op) when is_atom(op) do
    case Atom.to_string(op) do
      "OP_" <> n ->
        case Integer.parse(n) do
          {num, ""} -> num
          _ -> op
        end

      _ ->
        op
    end
  end

  defp field_key(<<n>>) when n <= 16, do: n
  defp field_key(tag), do: tag

  defp parent(<<hash::binary-32>>), do: outpoint(hash, 0)
  defp parent(<<hash::binary-32, vout::little-32>>), do: outpoint(hash, vout)
  defp parent(_), do: nil

  defp outpoint(hash, vout),
    do: "#{hash |> reverse() |> Base.encode16(case: :lower)}_#{vout}"

  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  # MAP inside an inscription field: the value is itself script-encoded pushes.
  defp decode_map(nil), do: %{}

  defp decode_map(value) do
    with {:ok, %BSV.Script{chunks: ["SET" | pairs]}} <- BSV.Script.from_binary(value) do
      pairs
      |> Enum.chunk_every(2, 2, :discard)
      |> Enum.filter(fn [k, v] -> is_binary(k) and is_binary(v) end)
      |> Map.new(fn [k, v] -> {k, decode_json_field(k, v)} end)
    else
      _ -> %{}
    end
  end

  defp decode_json_field("subTypeData", v) do
    case Jason.decode(v) do
      {:ok, decoded} -> decoded
      _ -> v
    end
  end

  defp decode_json_field(_k, v), do: v

  # P2PKH, alone or followed by an OP_RETURN note (1sat.market purchases
  # append MAP metadata after the lock).
  defp p2pkh_owner([
         :OP_DUP,
         :OP_HASH160,
         <<pkh::binary-20>>,
         :OP_EQUALVERIFY,
         :OP_CHECKSIG | rest
       ])
       when rest == [] or hd(rest) == :OP_RETURN,
       do: BSV.Address.to_string(%BSV.Address{pubkey_hash: pkh})

  defp p2pkh_owner(_), do: nil

  defp text(nil), do: nil
  defp text(bin), do: if(String.valid?(bin), do: bin, else: nil)
end
