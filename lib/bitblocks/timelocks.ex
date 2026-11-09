defmodule Bitblocks.Timelocks do
  @moduledoc """
  The `timelocks` table (#76): one row per time lock found in an output's
  script, as `Bitblocks.ScriptLocks` reads it, written by the
  `index_timelocks` tx step and its backfill
  (`Chain.TxPipeline.TimelocksBackfill`).

  A lock is a claim about one path through a script: `enforced` says whether
  the rules bind it at all (CLTV and CSV are NOPs for outputs created since
  Genesis), and `conditional` whether another branch can spend without it.

  A lock a HodLocker post or like makes names the post it backs
  (`backs_txid`), so `post_totals/1` sums what each post holds.

  Only a tx that can hold a lock is read: script analysis typed an output
  `unknown` (no P2PKH, P2PK, P2SH, multisig or data shape), or couldn't
  decode the tx at all. So the step costs nothing on an ordinary payment.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, RawTx, Transaction}
  alias Bitblocks.{HodLocker, Repo, ScriptLocks}
  alias Bitblocks.Timelocks.Lock

  @version 1

  @doc "The index_timelocks step's version, stamped on each row."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  True when a stored tx may hold a lock and has bytes to read: an output
  that script analysis left `unknown`, or no analysis yet.
  """
  @spec candidate?(Transaction.t()) :: boolean()
  def candidate?(%Transaction{raw: raw, output_types: types}) when is_binary(raw) and raw != "",
    do: is_nil(types) or Map.has_key?(types, "unknown")

  def candidate?(_tx), do: false

  @doc """
  The rows for a tx's locks: hex `raw`, mined in `block` (its height and
  time; nil when unknown). `[]` for a tx with no lock or that doesn't decode.
  """
  @spec rows(String.t(), String.t(), Block.t() | nil) :: [map()]
  def rows(txid, raw, block) do
    case RawTx.parse(raw) do
      {:ok, tx} ->
        height = block && block.height
        time = block && block.time

        case ScriptLocks.tx_locks(tx, height, time) do
          [] -> []
          locks -> to_rows(locks, tx, txid, height)
        end

      {:error, _} ->
        []
    end
  end

  defp to_rows(locks, tx, txid, height) do
    hodlocker = HodLocker.parse(tx, txid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for lock <- locks do
      backs = hodlocker && lock.kind == "1sat_lock" && hodlocker.post_txid

      lock
      |> Map.take([
        :vout,
        :op_index,
        :kind,
        :satoshis,
        :lock_value,
        :unlock_height,
        :unlock_time,
        :relative,
        :enforced,
        :conditional,
        :branch,
        :owner,
        :notes
      ])
      |> Map.merge(%{
        txid: txid,
        block_height: height,
        backs_txid: backs || nil,
        app: if(backs, do: "hodlocker"),
        version: @version,
        inserted_at: now,
        updated_at: now
      })
    end
  end

  @doc """
  Writes a stored tx's locks, mined in `block`. Idempotent on (txid, vout,
  op_index): a rerun rewrites the same rows. Returns how many it wrote.
  """
  @spec index(Transaction.t(), Block.t() | nil) :: non_neg_integer()
  def index(%Transaction{txid: txid, raw: raw} = tx, block) do
    if candidate?(tx), do: write(rows(txid, raw, block)), else: 0
  end

  @doc "Inserts rows, replacing a row already stored for the same lock."
  @spec write([map()]) :: non_neg_integer()
  def write([]), do: 0

  def write(rows) do
    {count, _} =
      Repo.insert_all(Lock, rows,
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:txid, :vout, :op_index]
      )

    count
  end

  @doc "The locks stored for a tx, by output and position."
  @spec for_tx(String.t()) :: [Lock.t()]
  def for_tx(txid) do
    Repo.all(from(l in Lock, where: l.txid == ^txid, order_by: [l.vout, l.op_index]))
  end

  @doc """
  What every lock we've indexed backs a HodLocker post with: the sats, how
  many locks and txs, how many of those txs are likes (any tx but the post
  itself), and the unlock heights' range. With `tip_height`,
  `locked_satoshis` is what is still locked above it (nil without one).
  Counts only what the table holds, so a range not yet backfilled is
  missing from it.
  """
  @spec post_totals(String.t(), non_neg_integer() | nil) :: map()
  def post_totals(post_txid, tip_height \\ nil) do
    totals =
      Repo.one(
        from(l in Lock,
          where: l.backs_txid == ^post_txid,
          select: %{
            satoshis: coalesce(sum(l.satoshis), 0),
            # Still locked at our tip: the unlock height is above it.
            locked_satoshis:
              fragment(
                "COALESCE(SUM(?) FILTER (WHERE ?::bigint IS NOT NULL AND ? > ?::bigint), 0)",
                l.satoshis,
                type(^tip_height, :integer),
                l.unlock_height,
                type(^tip_height, :integer)
              ),
            locks: count(l.id),
            txs: count(l.txid, :distinct),
            likes:
              fragment("COUNT(DISTINCT ?) FILTER (WHERE ? <> ?)", l.txid, l.txid, ^post_txid),
            first_unlock_height: min(l.unlock_height),
            last_unlock_height: max(l.unlock_height)
          }
        )
      )

    totals
    |> Map.update!(:satoshis, &to_integer/1)
    |> Map.update!(:locked_satoshis, &if(tip_height, do: to_integer(&1)))
    |> Map.put(:post_txid, post_txid)
  end

  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(n), do: n
end
