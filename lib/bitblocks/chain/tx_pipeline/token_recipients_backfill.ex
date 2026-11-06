defmodule Bitblocks.Chain.TxPipeline.TokenRecipientsBackfill do
  @moduledoc """
  Re-reads who holds each token output (#69, `docs/BSV20_TOKENS.md`).

  `Chain.index_tokens/1` writes a token row once, and a re-processed tx hits the
  `[:txid, :vout]` unique constraint, so a row stored while the lock couldn't be
  read keeps its nil `recipient` for good. This goes back over those rows: it
  picks BSV20 rows whose `recipient_version` is nil or below
  `Steps.IndexTokens.version/0`, reads each tx through `Chain.token_outputs/1`,
  the function ingest uses, and writes `recipient`, `lock` and `cosigner` with
  the stamp.

  A lock with no address to name is stamped too, with `lock: "other"`: the version
  computed it as unknown, so a rerun leaves it alone. A recipient already on a row
  is kept when the lock names none. A tx whose bytes can't be read stays below the
  version and is counted under `no_raw`.

  The range is on the row's `block_height`; a range starting at 0 also takes rows
  with no height. Paged by id, `:tx_batch` at a time, each page one short
  transaction under a statement timeout, with a pause after each write. The rows
  depend on no other row, so the order doesn't matter. Writes only the holder
  fields of `parsed_data`, the stamp and `updated_at`; transfer statuses don't
  depend on them. Dry run by default.
  Entry point: `Bitblocks.Release.backfill_token_recipients/3`.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Transaction, TxPipeline}
  alias Bitblocks.ProtocolRegistry.Instance
  alias Bitblocks.{Chain, Derivations, ProtocolRegistry, Repo, Tokens, TxStore}

  @doc """
  Runs over token rows from `from_height` to `to_height` inclusive and returns
  the `Derivations` report. `rows_examined` is the rows read, `rows_changed` the
  rows stamped (or, dry, to stamp), and `rows_below_version` the rows left below
  it: `no_raw` after an apply, every row picked after a dry run. `details` holds
  `recipients_filled` (nil before, an address now), `cosign`, `unknown_lock` and
  `no_raw`.

  Options: `apply: true` to write (default false); `tx_batch` (200); and the
  `Bitblocks.Derivations` options.
  """
  @spec run(integer(), integer(), keyword()) :: Derivations.report()
  def run(from_height, to_height, opts \\ []) do
    ctx = %{
      applied: Keyword.get(opts, :apply, false),
      from_height: from_height,
      to_height: to_height,
      tx_batch: Keyword.get(opts, :tx_batch, 200),
      version: TxPipeline.version(:token_recipients),
      protocol: ProtocolRegistry.get_protocol_by_name("BSV20"),
      opts: opts
    }

    Derivations.run(
      %{
        derivation: "token_recipients",
        version: ctx.version,
        from_height: from_height,
        to_height: to_height,
        cursor: 0,
        details: %{recipients_filled: 0, cosign: 0, unknown_lock: 0, no_raw: 0},
        next: &next(&1, &2, ctx)
      },
      opts
    )
  end

  defp next(_after_id, _report, %{protocol: nil}), do: :done

  defp next(after_id, report, ctx) do
    result =
      Derivations.bounded(ctx.opts, fn ->
        case page(after_id, ctx) do
          [] ->
            :done

          rows ->
            outcomes = read(rows)
            if ctx.applied, do: Enum.each(outcomes, &write(&1, ctx))
            outcomes
        end
      end)

    case result do
      :done ->
        :done

      outcomes ->
        if ctx.applied, do: Derivations.pause(ctx.opts)
        last = outcomes |> List.last() |> elem(0)
        {:cont, last.id, Enum.reduce(outcomes, report, &tally(&1, &2, ctx))}
    end
  end

  defp page(after_id, ctx) do
    from(i in Instance,
      where: i.protocol_id == ^ctx.protocol.id and i.id > ^after_id,
      where: is_nil(i.recipient_version) or i.recipient_version < ^ctx.version,
      order_by: i.id,
      limit: ^ctx.tx_batch
    )
    |> in_range(ctx)
    |> Repo.all()
  end

  defp in_range(query, %{from_height: from, to_height: to}) when from <= 0 do
    where(query, [i], is_nil(i.block_height) or i.block_height <= ^to)
  end

  defp in_range(query, %{from_height: from, to_height: to}) do
    where(query, [i], i.block_height >= ^from and i.block_height <= ^to)
  end

  # [{row, the token output its tx holds at row.vout, or nil}]
  defp read(rows) do
    txids = rows |> Enum.map(& &1.txid) |> Enum.uniq()

    txs =
      Repo.all(from(t in Transaction, where: t.txid in ^txids))
      |> Map.new(&{&1.txid, outputs_by_vout(&1)})

    Enum.map(rows, fn row -> {row, get_in(txs, [row.txid, row.vout])} end)
  end

  defp outputs_by_vout(tx) do
    with {:ok, tx} <- with_raw(tx),
         {:ok, outputs} <- Chain.token_outputs(tx) do
      Map.new(outputs, &{&1.vout, &1})
    else
      _ -> %{}
    end
  end

  # The row's own bytes, else the tx store's.
  defp with_raw(%Transaction{raw: raw} = tx) when is_binary(raw) and raw != "", do: {:ok, tx}

  defp with_raw(%Transaction{txid: txid} = tx) do
    with {:ok, bytes} <- TxStore.raw(txid) do
      {:ok, %{tx | raw: Base.encode16(bytes, case: :lower)}}
    end
  end

  defp write({_row, nil}, _ctx), do: :ok

  defp write({row, output}, ctx) do
    row
    |> Ecto.Changeset.change(parsed_data: holder(row, output), recipient_version: ctx.version)
    |> Repo.update!()
  end

  defp holder(row, output) do
    Tokens.put_holder(row.parsed_data, %{recipient: output.recipient, lock: output.lock})
  end

  defp tally({_row, nil}, report, _ctx) do
    report
    |> bump(:rows_examined)
    |> bump(:rows_below_version)
    |> detail(:no_raw)
  end

  defp tally({row, output}, report, ctx) do
    recipient = holder(row, output)["recipient"]
    filled? = is_nil(row.parsed_data["recipient"]) and not is_nil(recipient)

    report
    |> bump(:rows_examined)
    |> bump(:rows_changed)
    |> bump(:rows_below_version, not ctx.applied)
    |> detail(:recipients_filled, filled?)
    |> detail(:cosign, output.lock.type == "cosign")
    |> detail(:unknown_lock, is_nil(recipient))
  end

  defp bump(report, key, count? \\ true)
  defp bump(report, key, true), do: Map.update!(report, key, &(&1 + 1))
  defp bump(report, _key, false), do: report

  defp detail(report, key, count? \\ true)
  defp detail(report, key, true), do: update_in(report, [:details, key], &(&1 + 1))
  defp detail(report, _key, false), do: report
end
