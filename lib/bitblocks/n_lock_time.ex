defmodule Bitblocks.NLockTime do
  @moduledoc """
  A transaction's own lock, its `nLockTime` field (#76).

  A tx is not final, so no block may include it, until the height or time in
  `lock_time` has passed. Below 500,000,000 the value is a block height;
  from 500,000,000 on it is a unix time.

  The lock applies only when at least one input's `nSequence` is below
  `0xffffffff`. When every input is final, a nonzero lock time is ignored:
  the tx was valid at once, whatever the field says. `enforced?/1` asks
  both.

  ## Anti-fee-sniping

  From 2015, Bitcoin Core (and wallets after it) set the lock time of an
  ordinary payment to the tip's height at signing, sometimes up to 99
  blocks less, with a sequence of `0xfffffffe`. That lock binds, but the
  next block already meets it, so nobody waited on it: it is there to
  discourage miners from rewriting recent blocks. `near_tip?/2` marks such
  a lock against the block the tx was mined in: a height lock at most
  2,016 blocks below that block's height, or a time lock at most 14 days
  before its time (the same span).

  The window is two weeks: Bitcoin Core drops an unconfirmed tx from its
  mempool after 336 hours (`-mempoolexpiry`), so a payment signed with the
  tip's height and still unmined two weeks on has waited longer than the
  network keeps it. Real blocks agree (#76, read on WhatsOnChain, every
  binding lock time in each block sampled): the gap from lock time to
  mined height reached 487 blocks in block 400,000 and 761 in block
  420,000, payments that waited in the mempool, so a one-week window would
  be too tight. The tx typed in block 420,000's sample sits 4,167 blocks
  below it, signed about four weeks before it was mined.

  `typed?/2` decides the `nlocktime` type (`Bitblocks.TxTypes.Classifier`):
  enforced, and not near the tip of the block it was mined in. Without a
  block the gap can't be read, so the tx is not typed.

  Pure: reads a decoded `%BSV.Tx{}`, no database.
  """

  @threshold 500_000_000
  @final 0xFFFFFFFF
  @near_tip_blocks 2_016
  @near_tip_seconds 14 * 86_400

  @type t :: %{
          lock_time: pos_integer(),
          kind: :height | :time,
          enforced: boolean(),
          unlock_height: pos_integer() | nil,
          unlock_time: DateTime.t() | nil,
          near_tip: boolean() | nil
        }

  @typedoc "The block a tx was mined in: its height and unix time. Nil when unknown."
  @type block :: %{optional(atom()) => term()} | nil

  @doc "The value at which `lock_time` stops being a height and starts being a unix time."
  def threshold, do: @threshold

  @doc "How far below a block's height a height lock still reads as anti-fee-sniping."
  def near_tip_blocks, do: @near_tip_blocks

  @doc """
  The tx's lock time, read: its value, whether it is a height or a time,
  whether it is enforced, and, given the block it was mined in, whether it
  sits near that block's tip (`near_tip?/2`; nil without a block). Nil
  when `lock_time` is 0.
  """
  @spec parse(BSV.Tx.t(), block()) :: t() | nil
  def parse(tx, block \\ nil)

  def parse(%BSV.Tx{lock_time: lock_time} = tx, block)
      when is_integer(lock_time) and lock_time > 0 do
    {kind, height, time} =
      if lock_time < @threshold,
        do: {:height, lock_time, nil},
        else: {:time, nil, DateTime.from_unix!(lock_time)}

    %{
      lock_time: lock_time,
      kind: kind,
      enforced: enforced?(tx),
      unlock_height: height,
      unlock_time: time,
      near_tip: near_tip?(lock_time, block)
    }
  end

  def parse(_tx, _block), do: nil

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
  True when `lock_time` has the anti-fee-sniping shape against `block`, the
  block the tx was mined in: a height at most 2,016 below its height, or a
  time at most 14 days before its time. Nil when that height or time isn't
  known.
  """
  @spec near_tip?(non_neg_integer(), block()) :: boolean() | nil
  def near_tip?(lock_time, %{height: height})
      when lock_time < @threshold and is_integer(height),
      do: lock_time >= height - @near_tip_blocks

  def near_tip?(lock_time, %{time: time}) when lock_time >= @threshold and is_integer(time),
    do: lock_time >= time - @near_tip_seconds

  def near_tip?(_lock_time, _block), do: nil

  @doc """
  True when the tx is the `nlocktime` type: its lock time binds, and is not
  near the tip of `block`, the block it was mined in. False without a block.
  """
  @spec typed?(BSV.Tx.t(), block()) :: boolean()
  def typed?(%BSV.Tx{lock_time: lock_time} = tx, block) when is_integer(lock_time),
    do: enforced?(tx) and near_tip?(lock_time, block) == false

  def typed?(_tx, _block), do: false

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
