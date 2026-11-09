defmodule Bitblocks.ScriptLocks do
  @moduledoc """
  The time locks an output's script carries (#76), as found: one entry per
  lock, with where in the script it sits and whether it binds.

  Three kinds:

    * `"1sat_lock"`: the sCrypt Lockup contract of @1sat/templates
      (`Bitblocks.TimeLock`, the `timelock` type), which HodLocker used. It
      reads the spending tx's lock time with OP_PUSH_TX and checks it
      against the height in the output, so it binds on BSV today.
    * `"cltv"`: `OP_CHECKLOCKTIMEVERIFY` (byte 177) after a pushed value: a
      block height below 500,000,000, else a unix time.
    * `"csv"`: `OP_CHECKSEQUENCEVERIFY` (byte 178) after a pushed value: a
      relative lock of blocks, or of 512-second units, counted from the
      block the output was mined in (BIP 68).

  ## Enforced

  Bytes 177 and 178 did nothing (`OP_NOP2`, `OP_NOP3`) until BIP 65 made
  177 `OP_CHECKLOCKTIMEVERIFY` from block 388,381 and BIP 112 made 178
  `OP_CHECKSEQUENCEVERIFY` from block 419,328. Genesis (block 620,538) made
  them NOPs again for outputs created from then on, while older outputs keep
  the rules they were made under. So a CLTV or CSV lock is `enforced` only
  for an output mined in that window, and `nil` when we don't know the
  output's height.

  ## Conditional

  A lock inside an `OP_IF` or `OP_NOTIF` branch binds only on that path:
  another branch (or no branch, for an `IF` with no `ELSE`) may spend
  without it, for example with a cosigner or a hash preimage. Such a lock
  is `conditional`, with its `branch` path (`"OP_IF"`, `"OP_IF > OP_ELSE"`),
  and reads as "locked on one path", not as a fact about the output. A
  sibling branch that opens with `OP_RETURN` can never spend, so it doesn't
  make the lock conditional. A branch behind `OP_FALSE OP_IF` never runs
  (an inscription envelope), so a byte 177 there is data, not a lock.

  P2SH hides its redeem script until it is spent, so a CLTV inside a P2SH
  output isn't seen here. Data outputs (`OP_RETURN …`) hold no lock.

  Pure: reads decoded scripts, no database.
  """

  alias Bitblocks.TimeLock

  @cltv 177
  @csv 178
  @genesis 620_538
  @cltv_from 388_381
  @csv_from 419_328
  @time_threshold 500_000_000

  # BIP 68: bit 31 turns the relative lock off; bit 22 counts 512-second units.
  @csv_disable 0x80000000
  @csv_type_time 0x00400000
  @csv_mask 0x0000FFFF

  @type lock :: %{
          kind: String.t(),
          op_index: non_neg_integer(),
          lock_value: integer() | nil,
          unlock_height: non_neg_integer() | nil,
          unlock_time: DateTime.t() | nil,
          relative: boolean(),
          enforced: boolean() | nil,
          conditional: boolean(),
          branch: String.t() | nil,
          owner: String.t() | nil,
          notes: String.t() | nil
        }

  @doc "Genesis's height: CLTV and CSV are NOPs for outputs created from it on."
  def genesis_height, do: @genesis

  @doc """
  The locks in one output's script. `height` is the block the output was
  mined in, and `block_time` that block's unix time (for a CSV time lock);
  either may be nil.
  """
  @spec output_locks(BSV.Script.t(), non_neg_integer() | nil, integer() | nil) :: [lock()]
  def output_locks(script, height, block_time \\ nil)

  def output_locks(%BSV.Script{chunks: chunks} = script, height, block_time) do
    if data?(chunks) do
      []
    else
      case TimeLock.parse(script) do
        {:ok, lock} -> [one_sat_lock(lock)]
        :error -> opcode_locks(chunks, height, block_time)
      end
    end
  end

  def output_locks(_script, _height, _block_time), do: []

  @doc """
  The locks in every output of a decoded tx, each with its `vout` and
  `satoshis`, in output order.
  """
  @spec tx_locks(BSV.Tx.t(), non_neg_integer() | nil, integer() | nil) :: [map()]
  def tx_locks(%BSV.Tx{outputs: outputs}, height, block_time \\ nil) do
    for {%BSV.TxOut{script: script, satoshis: sats}, vout} <- Enum.with_index(outputs),
        lock <- output_locks(script, height, block_time) do
      Map.merge(lock, %{vout: vout, satoshis: sats})
    end
  end

  defp data?([:OP_RETURN | _]), do: true
  defp data?([zero, :OP_RETURN | _]) when zero in [:OP_FALSE, :OP_0], do: true
  defp data?(_), do: false

  defp one_sat_lock(%{unlock_height: height, owner: owner}) do
    %{
      kind: "1sat_lock",
      op_index: 0,
      lock_value: height,
      unlock_height: height,
      unlock_time: nil,
      relative: false,
      enforced: true,
      conditional: false,
      branch: nil,
      owner: owner,
      notes: nil
    }
  end

  # -- CLTV and CSV ---------------------------------------------------------

  defp opcode_locks(chunks, height, block_time) do
    indexed = chunks |> Enum.with_index() |> Enum.map(fn {c, i} -> {i, c} end)

    if Enum.any?(indexed, fn {_, c} -> opcode(c) in [@cltv, @csv] end) do
      tuple = List.to_tuple(chunks)
      branches = branches(indexed)

      Enum.flat_map(indexed, fn {i, chunk} ->
        code = opcode(chunk)
        frames = if code in [@cltv, @csv], do: enclosing(branches, i), else: []

        cond do
          code not in [@cltv, @csv] -> []
          Enum.any?(frames, & &1.dead) -> []
          true -> [lock(code, i, value_before(tuple, i), frames, tuple, height, block_time)]
        end
      end)
    else
      []
    end
  end

  defp value_before(_tuple, 0), do: nil

  defp value_before(tuple, i) do
    case script_number(elem(tuple, i - 1)) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp lock(code, i, value, frames, tuple, height, block_time) do
    conditional = Enum.any?(frames, &sibling_spendable?(&1, tuple))

    base = %{
      op_index: i,
      lock_value: value,
      unlock_height: nil,
      unlock_time: nil,
      relative: code == @csv,
      conditional: conditional,
      branch: branch_path(frames),
      owner: nil,
      notes: if(is_nil(value), do: "The value is computed by the script, not pushed.")
    }

    case code do
      @cltv -> Map.merge(base, cltv(value, height))
      @csv -> Map.merge(base, csv(value, height, block_time))
    end
  end

  defp cltv(value, height) do
    enforced = window?(height, @cltv_from)

    cond do
      is_nil(value) ->
        %{kind: "cltv", enforced: enforced}

      value < @time_threshold ->
        %{kind: "cltv", enforced: enforced, unlock_height: value}

      true ->
        %{kind: "cltv", enforced: enforced, unlock_time: DateTime.from_unix!(value)}
    end
  end

  defp csv(value, height, block_time) do
    enforced = window?(height, @csv_from)

    cond do
      is_nil(value) ->
        %{kind: "csv", enforced: enforced}

      Bitwise.band(value, @csv_disable) != 0 ->
        %{kind: "csv", enforced: false, notes: "The disable flag is set, so no relative lock."}

      Bitwise.band(value, @csv_type_time) != 0 ->
        seconds = Bitwise.band(value, @csv_mask) * 512

        %{
          kind: "csv",
          enforced: enforced,
          unlock_time: block_time && DateTime.from_unix!(block_time + seconds),
          notes: "#{seconds} seconds after the output's block."
        }

      true ->
        blocks = Bitwise.band(value, @csv_mask)

        %{
          kind: "csv",
          enforced: enforced,
          unlock_height: height && height + blocks,
          notes: "#{blocks} blocks after the output's block."
        }
    end
  end

  # Enforced only for an output mined after the opcode activated and before
  # Genesis; unknown without a height.
  defp window?(nil, _from), do: nil
  defp window?(height, from), do: height >= from and height < @genesis

  # -- Branches -------------------------------------------------------------

  # Every OP_IF/OP_NOTIF with its OP_ELSE and OP_ENDIF positions. An IF
  # opened by a pushed false (OP_FALSE OP_IF) never runs its first branch.
  defp branches(indexed) do
    {done, open, _prev} =
      Enum.reduce(indexed, {[], [], nil}, fn {i, chunk}, {done, open, prev} ->
        case {chunk, open} do
          {op, _} when op in [:OP_IF, :OP_NOTIF] ->
            frame = %{
              op: op,
              at: i,
              else: nil,
              endif: nil,
              never_then: op == :OP_IF and prev in [:OP_FALSE, :OP_0, <<>>]
            }

            {done, [frame | open], chunk}

          {:OP_ELSE, [frame | rest]} ->
            {done, [%{frame | else: i} | rest], chunk}

          {:OP_ENDIF, [frame | rest]} ->
            {[%{frame | endif: i} | done], rest, chunk}

          _ ->
            {done, open, chunk}
        end
      end)

    # An unclosed IF runs to the end of the script.
    done ++ Enum.map(open, &%{&1 | endif: length(indexed)})
  end

  # The branches that hold position i, outermost first, each with the side
  # it's on and whether that side can run.
  defp enclosing(branches, i) do
    branches
    |> Enum.filter(&(i > &1.at and i < &1.endif))
    |> Enum.sort_by(& &1.at)
    |> Enum.map(fn b ->
      side = if b.else && i > b.else, do: :else, else: :then
      Map.merge(b, %{side: side, dead: side == :then and b.never_then})
    end)
  end

  # The other side of the branch: an IF with no ELSE skips straight on, so
  # it can always spend; a side that opens with OP_RETURN never can.
  defp sibling_spendable?(%{else: nil}, _tuple), do: true

  defp sibling_spendable?(%{side: :then, else: e, endif: endif}, tuple),
    do: first_op(tuple, e + 1, endif) != :OP_RETURN

  defp sibling_spendable?(%{side: :else, at: at, else: e}, tuple),
    do: first_op(tuple, at + 1, e) != :OP_RETURN

  defp first_op(_tuple, from, to) when from >= to, do: nil
  defp first_op(tuple, from, _to), do: elem(tuple, from)

  defp branch_path([]), do: nil

  defp branch_path(frames) do
    Enum.map_join(frames, " > ", fn
      %{side: :else} -> "OP_ELSE"
      %{op: op} -> Atom.to_string(op)
    end)
  end

  # -- Values ---------------------------------------------------------------

  defp opcode(chunk) when is_atom(chunk), do: BSV.OpCode.to_integer(chunk)
  defp opcode(_chunk), do: nil

  # A script number: little-endian, the top bit of the last byte the sign.
  # CLTV and CSV read up to 5 bytes.
  defp script_number(<<>>), do: 0

  defp script_number(bytes) when is_binary(bytes) and byte_size(bytes) <= 5 do
    size = byte_size(bytes) * 8
    <<n::little-unsigned-size(size)>> = bytes
    sign = Bitwise.bsl(0x80, size - 8)

    if Bitwise.band(n, sign) == 0, do: n, else: -Bitwise.band(n, Bitwise.bnot(sign))
  end

  defp script_number(op) when op in [:OP_0, :OP_FALSE], do: 0
  defp script_number(:OP_1NEGATE), do: -1

  defp script_number(op) when is_atom(op) do
    code = BSV.OpCode.to_integer(op)
    if code in 0x51..0x60, do: code - 0x50
  end

  defp script_number(_), do: nil
end
