defmodule Bitblocks.Chain.TxIngestServerTimeoutTest do
  # #87: Postgres cancels a slow statement in a tx's insert transaction before
  # DBConnection's client timeout would kill the connection. The cancel is an
  # error naming the step, the tx isn't stored, and the connection carries on.
  use Bitblocks.DataCase, async: false

  import Bitblocks.OrdinalFixtures
  import ExUnit.CaptureLog

  alias Bitblocks.Chain.{Block, Transaction, TxIngest}

  defmodule SlowStep do
    def name, do: "slow_step"
    def stage, do: :tx
    def version, do: 1
    def run(_tx, _block), do: Bitblocks.Repo.query!("SELECT pg_sleep(2)")
  end

  setup do
    Application.put_env(:bitblocks, :tx_insert_statement_timeout_ms, 200)
    Application.put_env(:bitblocks, :tx_pipeline_extra_tx_steps, [SlowStep])

    on_exit(fn ->
      Application.delete_env(:bitblocks, :tx_insert_statement_timeout_ms)
      Application.delete_env(:bitblocks, :tx_pipeline_extra_tx_steps)
    end)
  end

  test "a step past the server timeout is canceled and named; the connection survives" do
    {txid, hex} = tx([funding_outpoint()], [p2pkh(address(), 5_000)])
    tx_json = %{"txid" => txid, "hex" => hex, "vin" => [], "vout" => []}

    log =
      capture_log(fn ->
        assert {:error, {:tx_step_failed, ^txid, "slow_step"}} =
                 TxIngest.store(tx_json, %Block{hash: "h", height: 1})
      end)

    assert log =~ "TxPipeline step slow_step failed"
    assert log =~ "statement timeout"
    refute Repo.get_by(Transaction, txid: txid)
    assert %{rows: [[1]]} = Repo.query!("SELECT 1")
  end
end
