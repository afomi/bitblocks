defmodule Bitblocks.DB.GinPendingTest do
  @moduledoc """
  The GIN pending-list cleanup (#87): it finds the GIN indexes on
  `transactions` and cleans each one, and the cron runs it on its own lane.
  """
  use Bitblocks.DataCase, async: true

  alias Bitblocks.DB.GinPending

  test "finds the GIN indexes on transactions" do
    indexes = GinPending.indexes()

    assert indexes != []
    assert Enum.any?(indexes, &(&1 =~ "output_addresses"))
  end

  test "cleans each index's pending list and reports the pages moved" do
    results = GinPending.run()

    assert length(results) == length(GinPending.indexes())

    for {index, pages} <- results do
      assert is_binary(index)
      assert is_integer(pages) and pages >= 0, "#{index}: #{inspect(pages)}"
    end
  end

  test "a table with no GIN index cleans nothing" do
    assert GinPending.run("blocks") |> Enum.all?(fn {_, pages} -> is_integer(pages) end)
  end

  test "runs every minute on the maintenance lane, one at a time" do
    crontab =
      Application.fetch_env!(:bitblocks, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert {"* * * * *", Bitblocks.Workers.GinPendingWorker} in crontab
    assert Bitblocks.Workers.GinPendingWorker.__opts__()[:queue] == :maintenance
  end

  describe "the cleanup job's uniqueness (https://github.com/afomi/bitblocks/issues/212)" do
    alias Bitblocks.Workers.GinPendingWorker

    defp executing_since(minutes_ago) do
      {:ok, job} = Oban.insert(GinPendingWorker.new(%{}))
      at = DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)

      job
      |> Ecto.Changeset.change(state: "executing", inserted_at: at, attempted_at: at)
      |> Bitblocks.Repo.update!()
    end

    test "a run in progress blocks the next cron insert" do
      executing_since(1)
      assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(GinPendingWorker.new(%{}))
    end

    test "a run orphaned by a deploy stops blocking after five minutes" do
      executing_since(10)
      assert {:ok, %Oban.Job{conflict?: false}} = Oban.insert(GinPendingWorker.new(%{}))
    end
  end
end
