defmodule Bitblocks.NLockTime do
  @moduledoc """
  A transaction's own lock, its `nLockTime` field (#76).

  A tx is not final, so no block may include it, until the height or time in
  `lock_time` has passed. Below 500,000,000 the value is a block height;
  from 500,000,000 on it is a unix time.

  The lock applies only when at least one input's `nSequence` is below
  `0xffffffff`. When every input is final, a nonzero lock time is ignored:
  the tx was valid at once, whatever the field says. So `enforced?/1` asks
  both, and only an enforced lock makes a tx the `nlocktime` type
  (`Bitblocks.TxTypes.Classifier`).

  Pure: reads a decoded `%BSV.Tx{}`, no database.
  """

  @threshold 500_000_000
  @final 0xFFFFFFFF

  @type t :: %{
          lock_time: pos_integer(),
          kind: :height | :time,
          enforced: boolean(),
          unlock_height: pos_integer() | nil,
          unlock_time: DateTime.t() | nil
        }

  @doc "The value at which `lock_time` stops being a height and starts being a unix time."
  def threshold, do: @threshold

  @doc """
  The tx's lock time, read: its value, whether it is a height or a time,
  and whether it is enforced. Nil when `lock_time` is 0.
  """
  @spec parse(BSV.Tx.t()) :: t() | nil
  def parse(%BSV.Tx{lock_time: lock_time} = tx) when is_integer(lock_time) and lock_time > 0 do
    {kind, height, time} =
      if lock_time < @threshold,
        do: {:height, lock_time, nil},
        else: {:time, nil, DateTime.from_unix!(lock_time)}

    %{
      lock_time: lock_time,
      kind: kind,
      enforced: enforced?(tx),
      unlock_height: height,
      unlock_time: time
    }
  end

  def parse(_tx), do: nil

  @doc """
  True when the lock time binds: it is nonzero and at least one input's
  sequence is below `0xffffffff`.
  """
  @spec enforced?(BSV.Tx.t()) :: boolean()
  def enforced?(%BSV.Tx{lock_time: lock_time, inputs: inputs})
      when is_integer(lock_time) and lock_time > 0,
      do: Enum.any?(inputs, &non_final?/1)

  def enforced?(_tx), do: false

  defp non_final?(%BSV.TxIn{sequence: sequence}) when is_integer(sequence),
    do: sequence < @final

  defp non_final?(_input), do: false

  @doc """
  Whether the lock has passed, against our tip: `:reached`, `{:waiting,
  blocks_left}` for a height, `:waiting` for a time, or `:unknown` with no
  tip. A tx can go in the first block above its height (or whose median
  time is past its time), so a height lock is reached once the tip is at
  it. A time lock is compared with the tip block's time, which runs a
  little ahead of the median time the rule uses.
  """
  @spec state(t(), non_neg_integer() | nil, DateTime.t() | nil) ::
          :reached | :waiting | {:waiting, pos_integer()} | :unknown
  def state(%{kind: :height}, nil, _tip_time), do: :unknown
  def state(%{kind: :height, unlock_height: h}, tip, _) when tip >= h, do: :reached
  def state(%{kind: :height, unlock_height: h}, tip, _), do: {:waiting, h - tip}
  def state(%{kind: :time}, _tip, nil), do: :unknown

  def state(%{kind: :time, unlock_time: time}, _tip, %DateTime{} = tip_time),
    do: if(DateTime.compare(tip_time, time) == :lt, do: :waiting, else: :reached)
end
