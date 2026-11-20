defmodule Bitblocks.Chain.TxPipeline.CFilesBackfill do
  @moduledoc """
  Fills `c_files` for rows stored before the `index_c_files` step existed,
  or below its version (https://github.com/afomi/bitblocks/issues/147,
  `docs/DERIVED_DATA.md`).

  Writes only to `c_files`, never to `transactions`.

  Walks the txs tagged `B://` through their own partial index
  (`transactions_b_protocol_id_index`, the one `/files` reads) in id order,
  `:tx_batch` at a time, keeping those mined in the range. B:// txs are
  rare, so a run over the whole chain reads that small index once and never
  walks blocks or the primary key. Each page is one short transaction under
  a statement timeout, with a pause after each write.

  Bytes come from the row, else from the tx store (`TxStore.with_raw/1`;
  never WhatsOnChain). A tagged tx whose bytes we hold nowhere is counted
  under `details.no_raw` and left for a later run.

  Idempotent on (txid, vout): a file already stored at the current version
  is not written again, so a rerun after a full apply writes nothing. Dry
  run by default. Entry point: `Bitblocks.Release.backfill_c_files/3`.
  """

  import Ecto.Query

  alias Bitblocks.{CFiles, Derivations, Repo, TxStore}
  alias Bitblocks.CFiles.CFile
  alias Bitblocks.Chain.Transaction

  @doc """
  Runs over the B:// txs mined at heights `from_height` to `to_height`
  inclusive and returns the `Derivations` report: `rows_examined` is the
  tagged txs read, `rows_changed` the file rows written (or, dry, to
  write), and `rows_below_version` the file rows in the range still missing
  or below the version. `details` counts `files_found`, `no_file` (tagged,
  but no B:// file of its own) and `no_raw`.

  Options: `apply: true` to write (default false); `tx_batch` (200); and
  the `Bitblocks.Derivations` options.
  """
  @spec run(non_neg_integer(), non_neg_integer(), keyword()) :: Derivations.report()
  def run(from_height, to_height, opts \\ []) do
    ctx = %{
      applied: Keyword.get(opts, :apply, false),
      from_height: from_height,
      to_height: to_height,
      tx_batch: Keyword.get(opts, :tx_batch, 200),
      version: CFiles.version(),
      opts: opts
    }

    Derivations.run(
      %{
        derivation: "c_files",
        version: ctx.version,
        from_height: from_height,
        to_height: to_height,
        cursor: 0,
        details: %{files_found: 0, no_file: 0, no_raw: 0},
        next: &next(&1, &2, ctx)
      },
      opts
    )
  end

  # One page of tagged txs after the cursor (a tx id).
  defp next(after_id, report, ctx) do
    started = Derivations.now()

    result =
      Derivations.bounded(ctx.opts, fn ->
        case after_id |> page(ctx) |> Derivations.fill_raw(ctx.opts) do
          [] -> :done
          txs -> {txs, Enum.map(txs, &tx(&1, ctx))}
        end
      end)

    case result do
      :done ->
        :done

      {txs, outcomes} ->
        Derivations.page_took(length(txs), started)
        if ctx.applied, do: Derivations.pause(ctx.opts)

        report =
          Enum.reduce(outcomes, bump(report, :rows_examined, length(txs)), &tally(&1, &2, ctx))

        {:cont, List.last(txs).id, report}
    end
  end

  # The tag is a literal, spelled as the partial index's predicate, so the
  # planner can prove the index applies (Bitcom.Files.b_tagged/0 says why).
  defp page(after_id, ctx), do: after_id |> page_query(ctx) |> Repo.all()

  @doc false
  # The page query, for the test that reads its plan.
  def page_query(after_id, ctx) do
    from(t in Transaction,
      where: fragment("? @> ARRAY['B://']::varchar[]", t.protocols),
      where: t.id > ^after_id,
      where: t.block_height >= ^ctx.from_height and t.block_height <= ^ctx.to_height,
      order_by: [asc: t.id],
      limit: ^Derivations.page_limit(ctx.tx_batch),
      # Only the size; `Derivations.fill_raw/2` loads the bytes.
      select: %{
        id: t.id,
        txid: t.txid,
        block_height: t.block_height,
        raw_bytes: fragment("octet_length(?)", t.raw)
      }
    )
  end

  defp tx(row, ctx) do
    case TxStore.with_raw(row) do
      %{raw: raw} when is_binary(raw) and raw != "" ->
        rows = CFiles.rows(row.txid, raw, row.block_height)
        missing = missing(rows, row.txid, ctx.version)
        if ctx.applied, do: CFiles.write(missing)
        {rows, length(missing)}

      _ ->
        :no_raw
    end
  end

  # The rows not yet stored at the current version.
  defp missing([], _txid, _version), do: []

  defp missing(rows, txid, version) do
    current =
      Repo.all(
        from(c in CFile,
          where: c.txid == ^txid and c.version >= ^version,
          select: {c.vout, c.sha256}
        )
      )
      |> MapSet.new()

    Enum.reject(rows, &MapSet.member?(current, {&1.vout, &1.sha256}))
  end

  defp tally(:no_raw, report, _ctx), do: update_in(report, [:details, :no_raw], &(&1 + 1))

  defp tally({rows, written}, report, ctx) do
    report
    |> bump(:rows_changed, written)
    |> bump(:rows_below_version, if(ctx.applied, do: 0, else: written))
    |> update_in([:details], fn d ->
      d
      |> Map.update!(:files_found, &(&1 + length(rows)))
      |> Map.update!(:no_file, &(&1 + if(rows == [], do: 1, else: 0)))
    end)
  end

  defp bump(report, key, n), do: Map.update!(report, key, &(&1 + n))
end
