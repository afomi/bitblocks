defmodule Bitblocks.ReleaseTxSizesTest do
  # A tx's size and whether its bytes are in the row (docs/TX_STORAGE.md): set
  # on every new row, filled on older ones, and a rerun finds nothing.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{RawBlock, Transaction, TxIngest}
  alias Bitblocks.Derivations.Run
  alias Bitblocks.Release

  defp tx_json({txid, hex}), do: RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))

  defp quietly(fun) do
    output = capture_io(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    {result, output}
  end

  setup do
    {txid, hex} = pair = tx([funding_outpoint()], [p2pkh(address(), 1_000)])
    :ok = TxIngest.store(tx_json(pair), block_fixture(%{height: 80}))
    %{txid: txid, size: div(byte_size(hex), 2)}
  end

  defp forget_sizes do
    Repo.update_all(Transaction, set: [size_bytes: nil, raw_in_db: nil])
  end

  test "a stored tx carries its size and says its bytes are in the row", ctx do
    assert %{size_bytes: size, raw_in_db: true} = Chain.get_transaction!(ctx.txid)
    assert size == ctx.size
  end

  test "a dry run counts rows and writes only its run record", ctx do
    forget_sizes()
    {report, output} = quietly(fn -> Release.backfill_tx_sizes() end)

    assert %{applied: false, outcome: "ok", rows_changed: 1, rows_below_version: 1} = report
    assert output =~ "DRY RUN (nothing written)"
    assert %{size_bytes: nil, raw_in_db: nil} = Chain.get_transaction!(ctx.txid)
    assert %Run{derivation: "tx_size", applied: false} = Repo.get!(Run, report.run_id)
  end

  test "apply fills older rows; a rerun finds nothing", ctx do
    forget_sizes()
    {report, _} = quietly(fn -> Release.backfill_tx_sizes(apply: true, id_window: 1) end)

    assert %{outcome: "ok", rows_changed: 1, rows_below_version: 0} = report
    assert %{size_bytes: size, raw_in_db: true} = Chain.get_transaction!(ctx.txid)
    assert size == ctx.size

    {rerun, _} = quietly(fn -> Release.backfill_tx_sizes() end)
    assert %{rows_changed: 0, rows_below_version: 0} = rerun
  end

  test "a tx over the threshold is counted, and keeps its bytes until they move", ctx do
    forget_sizes()
    big = String.duplicate("ab", Transaction.raw_in_db_max_bytes() + 1)
    Repo.update_all(from(t in Transaction, where: t.txid == ^ctx.txid), set: [raw: big])

    {report, _} = quietly(fn -> Release.backfill_tx_sizes(apply: true) end)

    assert report.details.over_threshold == 1
    assert %{size_bytes: size, raw_in_db: true} = Chain.get_transaction!(ctx.txid)
    assert size == Transaction.raw_in_db_max_bytes() + 1
  end

  test "a row with no bytes says so, and keeps the size the store recorded", ctx do
    forget_sizes()

    Repo.update_all(from(t in Transaction, where: t.txid == ^ctx.txid),
      set: [raw: "", raw_length: 1_234_567]
    )

    {report, _} = quietly(fn -> Release.backfill_tx_sizes(apply: true) end)

    assert report.details.no_raw == 1

    assert %{size_bytes: 1_234_567, raw_in_db: false} = Chain.get_transaction!(ctx.txid)
  end
end
