defmodule Bitblocks.Workers.OpsAlertWorkerTest do
  use Bitblocks.DataCase, async: false

  alias Bitblocks.Workers.OpsAlertWorker

  test "runs a health check and alerts on what it finds" do
    Bitblocks.Ops.reset_alerts()
    assert :ok = perform_job(OpsAlertWorker, %{})
  end

  describe "the database size alarm" do
    import Swoosh.TestAssertions

    alias Bitblocks.Ops

    setup do
      Ops.reset_alerts()
      on_exit(&Ops.reset_alerts/0)
    end

    test "stays quiet at the limit" do
      assert Ops.alert_db_size(700_000_000_000) == []
      assert_no_email_sent()
    end

    test "past the limit it emails once, then waits" do
      assert Ops.alert_db_size(712_000_000_000) == ["db_size"]
      assert_email_sent(subject: "Bitblocks: database at 712 GB")

      assert Ops.alert_db_size(713_000_000_000) == []
      assert_no_email_sent()
    end

    test "reads the real size without alarming a small database" do
      assert Ops.alert_db_size() == []
    end
  end

  defp perform_job(worker, args), do: worker.perform(%Oban.Job{args: args})
end
