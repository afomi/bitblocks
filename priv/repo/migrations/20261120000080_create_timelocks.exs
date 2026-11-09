defmodule Bitblocks.Repo.Migrations.CreateTimelocks do
  use Ecto.Migration

  # One time lock found in an output's script (#76), as found: a claim about
  # one path through the script, not always about the output
  # (Bitblocks.ScriptLocks). A tx's own nLockTime is not here: it is the
  # `nlocktime` tx type, read from the tx when shown.
  #
  # Most outputs carry no lock, so this table stays small, and filling it
  # never touches `transactions`.
  #
  # txid, vout     — the output.
  # op_index       — the lock opcode's position among the script's chunks
  #                  (0 for a 1Sat Lock), so a script with a lock on each
  #                  branch has a row per lock.
  # kind           — "1sat_lock", "cltv" or "csv".
  # block_height   — the block the output was mined in; a CLTV or CSV lock
  #                  binds only for an output mined before Genesis.
  # satoshis       — the output's value.
  # lock_value     — the number the script compares with, as pushed; nil
  #                  when the script computes it.
  # unlock_height  — the first height it can be spent from, when the lock is
  #                  a height (for CSV, the output's height plus its blocks).
  # unlock_time    — the time it can be spent from, when the lock is a time.
  # relative       — true for CSV, counted from the output's block.
  # enforced       — whether the rules enforce it: true for a 1Sat Lock;
  #                  for CLTV and CSV, only between their activation and
  #                  Genesis; nil without a height.
  # conditional    — true when another branch can spend without the lock:
  #                  "locked on one path".
  # branch         — the branch path that holds it ("OP_IF", "OP_IF > OP_ELSE").
  # owner          — who may spend once it ends, when the script names one.
  # backs_txid     — the post a HodLocker post or like backs with this lock.
  # app            — the app that made it, when known ("hodlocker").
  # notes          — anything else read from the script.
  # version        — the index_timelocks step's version that wrote the row.
  def change do
    create table(:timelocks) do
      add(:txid, :string, null: false)
      add(:vout, :integer, null: false)
      add(:op_index, :integer, null: false)
      add(:kind, :string, null: false)
      add(:block_height, :integer)
      add(:satoshis, :bigint)
      add(:lock_value, :bigint)
      add(:unlock_height, :bigint)
      add(:unlock_time, :utc_datetime)
      add(:relative, :boolean, null: false, default: false)
      add(:enforced, :boolean)
      add(:conditional, :boolean, null: false, default: false)
      add(:branch, :string)
      add(:owner, :string)
      add(:backs_txid, :string)
      add(:app, :string)
      add(:notes, :text)
      add(:version, :integer, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:timelocks, [:txid, :vout, :op_index]))
    create(index(:timelocks, [:block_height]))
    create(index(:timelocks, [:backs_txid]))
    create(index(:timelocks, [:owner]))
  end
end
