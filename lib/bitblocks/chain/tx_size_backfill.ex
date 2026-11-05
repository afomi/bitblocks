defmodule Bitblocks.Chain.TxSizeBackfill do
  @moduledoc """
  Fills `transactions.size_bytes` and `raw_in_db` on rows stored before those
  columns existed (`docs/TX_STORAGE.md`). A new row gets both from
  `Transaction.changeset/2`.

  Selects rows with a nil `raw_in_db`, so a rerun after a full apply finds
  nothing and a stopped run resumes. A row with no raw bytes gets
  `raw_in_db: false` and the size the tx store recorded (`raw_length`), nil
  if it has none; the report counts those under `details.no_raw`.

  Bounded: id windows of `:id_window` on the primary key, one statement each
  under a statement timeout, with a pause after each write. No decoding and
  no `updated_at`, which dates the tallies. Dry run by default.
  """

  import Ecto.Query

  alias Bitblocks.Chain.Transaction
  alias Bitblocks.{Derivations, Repo}

  @doc """
  Runs over every stored tx and returns the `Derivations` report; `details`
  holds `over_threshold` (rows above `Transaction.raw_in_db_max_bytes/0`) and
  `no_raw`. Options: `apply: true` to write (default false); `id_window`
  (5,000); and the `Bitblocks.Derivations` options.
  """
  @spec run(keyword()) :: Derivations.report()
  def run(opts \\ []) do
    ctx = %{
      applied: Keyword.get(opts, :apply, false),
      window: Keyword.get(opts, :id_window, 5_000),
      last_id: Repo.aggregate(Transaction, :max, :id) || 0,
      opts: opts
    }

    Derivations.run(
      %{
        derivation: "tx_size",
        version: 1,
        from_height: nil,
        to_height: nil,
        cursor: 0,
        details: %{over_threshold: 0, no_raw: 0},
        next: &next(&1, &2, ctx)
      },
      opts
    )
  end

  defp next(after_id, _report, %{last_id: last}) when after_id >= last, do: :done

  defp next(after_id, report, ctx) do
    upto = after_id + ctx.window

    {found, over, no_raw} =
      Derivations.bounded(ctx.opts, fn ->
        counts = counts(after_id, upto)
        if ctx.applied, do: write(after_id, upto)
        counts
      end)

    if ctx.applied and found > 0, do: Derivations.pause(ctx.opts)

    report =
      report
      |> bump(:rows_examined, found)
      |> bump(:rows_changed, found)
      |> bump(:rows_below_version, if(ctx.applied, do: 0, else: found))
      |> update_in([:details, :over_threshold], &(&1 + over))
      |> update_in([:details, :no_raw], &(&1 + no_raw))

    {:cont, upto, report}
  end

  defp counts(after_id, upto) do
    max = Transaction.raw_in_db_max_bytes()

    Repo.one(
      from(t in unfilled(after_id, upto),
        select:
          {count(), fragment("count(*) FILTER (WHERE length(?) / 2 > ?)", t.raw, ^max),
           fragment("count(*) FILTER (WHERE ? IS NULL OR ? = '')", t.raw, t.raw)}
      )
    )
  end

  defp write(after_id, upto) do
    Repo.update_all(
      from(t in unfilled(after_id, upto),
        update: [
          set: [
            size_bytes:
              fragment(
                "CASE WHEN coalesce(?, '') = '' THEN ? ELSE length(?) / 2 END",
                t.raw,
                t.raw_length,
                t.raw
              ),
            raw_in_db: fragment("coalesce(?, '') <> ''", t.raw)
          ]
        ]
      ),
      []
    )
  end

  defp unfilled(after_id, upto) do
    from(t in Transaction, where: t.id > ^after_id and t.id <= ^upto and is_nil(t.raw_in_db))
  end

  defp bump(report, key, n), do: Map.update!(report, key, &(&1 + n))
end
