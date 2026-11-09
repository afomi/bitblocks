defmodule Bitblocks.TimeLock do
  @moduledoc """
  Reads a time lock output: the `timelock` type in
  `priv/data/tx_types/types.json`, the sCrypt Lockup contract that
  @1sat/templates ships and HodLocker used (#75).

  The contract opens with three fixed pushes and two `OP_0`s, then the two
  arguments, then `OP_NOP` and the fixed code:

      <fixed> <fixed> <fixed> OP_0 OP_0 <owner pubkey hash, 20> <unlock height> OP_NOP …

  The unlock height is a script number (little-endian, sign bit high). The
  output can be spent by the owner's signature once a transaction with that
  lock time is valid, so from the block at that height on.

  Matched by template hash (the timelock type's `examples.template_hashes`),
  so only the shape that type names is read.
  """

  alias Bitblocks.{Script, TxTypes}

  @template_hashes "timelock"
                   |> TxTypes.get()
                   |> Map.fetch!(:examples)
                   |> Map.fetch!(:template_hashes)

  @type t :: %{owner_pkh: String.t(), owner: String.t(), unlock_height: non_neg_integer()}

  @doc "The owner and unlock height of a time lock output, or `:error`."
  @spec parse(BSV.Script.t()) :: {:ok, t()} | :error
  def parse(%BSV.Script{chunks: chunks} = script) do
    with true <- Script.template_hash(script) in @template_hashes,
         [_, _, _, zero, zero, <<pkh::binary-20>>, height, :OP_NOP | _]
         when zero in [:OP_0, :OP_FALSE] <- chunks,
         {:ok, height} <- script_number(height) do
      {:ok,
       %{
         owner_pkh: Base.encode16(pkh, case: :lower),
         owner: %BSV.Address{pubkey_hash: pkh} |> BSV.Address.to_string(),
         unlock_height: height
       }}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  # A positive script number: little-endian, the top bit of the last byte
  # the sign. A small height could be an OP_1..OP_16 opcode.
  defp script_number(bytes) when is_binary(bytes) and byte_size(bytes) in 1..5 do
    <<n::little-unsigned-size(byte_size(bytes) * 8)>> = bytes
    sign = Bitwise.bsl(0x80, (byte_size(bytes) - 1) * 8)

    if Bitwise.band(n, sign) == 0, do: {:ok, n}, else: :error
  end

  defp script_number(opcode) when is_atom(opcode) do
    case opcode |> Atom.to_string() |> String.replace_prefix("OP_", "") |> Integer.parse() do
      {n, ""} when n in 1..16 -> {:ok, n}
      _ -> :error
    end
  end

  defp script_number(_), do: :error
end
