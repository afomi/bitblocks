defmodule Bitblocks.Chain.RawTx do
  @moduledoc """
  A tolerant transaction decoder. `BSV.Tx.from_binary` raises when any script
  in the tx doesn't parse as opcodes, but Bitcoin allows arbitrary script bytes
  (data after a contract often isn't valid pushes). This reads the tx
  structure itself and parses each script as far as it goes: chunks up to the
  first byte that isn't a complete opcode or push are kept, and the rest is
  kept as one trailing binary, so an inscription envelope and lock ahead of
  unparseable bytes are still readable.

  Returns the same `%BSV.Tx{}` shape as `BSV.Tx.from_binary/2`.
  """

  @doc "Decodes a hex tx. `{:ok, %BSV.Tx{}}` or `{:error, :invalid_tx}`."
  @spec parse(String.t()) :: {:ok, BSV.Tx.t()} | {:error, :invalid_tx}
  def parse(hex) when is_binary(hex) do
    with {:ok, bytes} <- Base.decode16(hex, case: :mixed),
         {:ok, tx} <- tx(bytes) do
      {:ok, tx}
    else
      _ -> {:error, :invalid_tx}
    end
  end

  @doc """
  The value flows of a hex tx, without parsing any script: each input's
  previous outpoint (`{prev_txid, vout}`, or `:coinbase`) and each output's
  `{satoshis, script_bytes}`, in order. Exact integers, unlike the `value`
  floats in getrawtransaction JSON. The tx pipeline's tallies read this.

  `{:ok, %{inputs: [...], outputs: [...]}}` or `{:error, :invalid_tx}`.
  """
  @spec flows(String.t()) ::
          {:ok,
           %{
             inputs: [:coinbase | {String.t(), non_neg_integer()}],
             outputs: [{non_neg_integer(), binary()}]
           }}
          | {:error, :invalid_tx}
  def flows(hex) when is_binary(hex) do
    with {:ok, <<_version::little-32, rest::binary>>} <- Base.decode16(hex, case: :mixed),
         {:ok, inputs, rest} <- items(rest, &flow_input/1),
         {:ok, outputs, <<_lock_time::little-32>>} <- items(rest, &flow_output/1) do
      {:ok, %{inputs: inputs, outputs: outputs}}
    else
      _ -> {:error, :invalid_tx}
    end
  end

  def flows(_), do: {:error, :invalid_tx}

  @null_hash <<0::256>>

  defp flow_input(<<hash::binary-32, vout::little-32, rest::binary>>) do
    with {:ok, _script, <<_sequence::little-32, rest::binary>>} <- script_bytes(rest) do
      outpoint =
        if hash == @null_hash and vout == 0xFFFFFFFF,
          do: :coinbase,
          else: {hash |> reverse() |> Base.encode16(case: :lower), vout}

      {:ok, outpoint, rest}
    else
      _ -> :error
    end
  end

  defp flow_input(_), do: :error

  defp flow_output(<<satoshis::little-64, rest::binary>>) do
    case script_bytes(rest) do
      {:ok, script, rest} -> {:ok, {satoshis, script}, rest}
      _ -> :error
    end
  end

  defp flow_output(_), do: :error

  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  defp tx(<<version::little-32, rest::binary>>) do
    with {:ok, inputs, rest} <- items(rest, &input/1),
         {:ok, outputs, <<lock_time::little-32>>} <- items(rest, &output/1) do
      {:ok, %BSV.Tx{version: version, inputs: inputs, outputs: outputs, lock_time: lock_time}}
    else
      _ -> :error
    end
  end

  defp tx(_), do: :error

  defp items(bytes, parse_one) do
    with {:ok, count, rest} <- varint(bytes) do
      Enum.reduce_while(1..count//1, {:ok, [], rest}, fn _, {:ok, acc, rest} ->
        case parse_one.(rest) do
          {:ok, item, rest} -> {:cont, {:ok, [item | acc], rest}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, acc, rest} -> {:ok, Enum.reverse(acc), rest}
        :error -> :error
      end
    end
  end

  defp input(<<hash::binary-32, vout::little-32, rest::binary>>) do
    with {:ok, script, <<sequence::little-32, rest::binary>>} <- script_bytes(rest) do
      {:ok,
       %BSV.TxIn{
         outpoint: %BSV.OutPoint{hash: hash, vout: vout},
         script: script(script),
         sequence: sequence
       }, rest}
    else
      _ -> :error
    end
  end

  defp input(_), do: :error

  defp output(<<satoshis::little-64, rest::binary>>) do
    case script_bytes(rest) do
      {:ok, script, rest} -> {:ok, %BSV.TxOut{satoshis: satoshis, script: script(script)}, rest}
      _ -> :error
    end
  end

  defp output(_), do: :error

  defp script_bytes(bytes) do
    with {:ok, len, rest} <- varint(bytes),
         <<script::binary-size(len), rest::binary>> <- rest do
      {:ok, script, rest}
    else
      _ -> :error
    end
  end

  defp varint(<<0xFD, n::little-16, rest::binary>>), do: {:ok, n, rest}
  defp varint(<<0xFE, n::little-32, rest::binary>>), do: {:ok, n, rest}
  defp varint(<<0xFF, n::little-64, rest::binary>>), do: {:ok, n, rest}
  defp varint(<<n, rest::binary>>), do: {:ok, n, rest}
  defp varint(_), do: :error

  @doc false
  def script(bytes), do: %BSV.Script{chunks: chunks(bytes, [])}

  defp chunks(<<>>, acc), do: Enum.reverse(acc)

  defp chunks(<<n, rest::binary>> = bytes, acc) when n in 1..75 do
    case rest do
      <<data::binary-size(n), rest::binary>> -> chunks(rest, [data | acc])
      _ -> Enum.reverse([bytes | acc])
    end
  end

  defp chunks(<<0x4C, n, data::binary-size(n), rest::binary>>, acc),
    do: chunks(rest, [data | acc])

  defp chunks(<<0x4D, n::little-16, data::binary-size(n), rest::binary>>, acc),
    do: chunks(rest, [data | acc])

  defp chunks(<<0x4E, n::little-32, data::binary-size(n), rest::binary>>, acc),
    do: chunks(rest, [data | acc])

  defp chunks(<<op, rest::binary>> = bytes, acc) when op not in [0x4C, 0x4D, 0x4E] do
    case opcode(op) do
      {:ok, atom} -> chunks(rest, [atom | acc])
      :error -> Enum.reverse([bytes | acc])
    end
  end

  # A truncated PUSHDATA: keep the remainder as one binary.
  defp chunks(bytes, acc), do: Enum.reverse([bytes | acc])

  defp opcode(byte) do
    {:ok, BSV.OpCode.to_atom!(byte)}
  rescue
    _ -> :error
  end
end
