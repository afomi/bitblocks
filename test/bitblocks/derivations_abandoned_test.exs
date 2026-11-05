defmodule Bitblocks.DerivationsAbandonedTest do
  # A run whose process died (a deploy restart) stays `running` forever.
  # `close_abandoned/2` closes the ones an operator names, or those started
  # before a cutoff, as `abandoned`; a dry run changes nothing, and a run
  # that already finished is never touched.
  use Bitblocks.DataCase, async: false

  import ExUnit.CaptureIO

  alias Bitblocks.Derivations
  alias Bitblocks.Derivations.Run
  alias Bitblocks.Release

  defp run!(outcome, started_at) do
    Repo.insert!(%Run{
      derivation: "tallies",
      version: 1,
      from_height: 0,
      to_height: 9_999,
      applied: true,
      outcome: outcome,
      started_at: started_at
    })
  end

  defp hours_ago(h), do: DateTime.add(DateTime.utc_now(), -h * 3_600, :second)

  test "closes the named running runs as abandoned, and leaves finished ones alone" do
    stuck = run!("running", hours_ago(3))
    live = run!("running", hours_ago(0))
    done = run!("ok", hours_ago(3))

    assert %{closed: [id], skipped: [skipped]} =
             Derivations.close_abandoned([ids: [stuck.id, done.id]], apply: true)

    assert id == stuck.id
    assert skipped == done.id

    assert %Run{outcome: "abandoned", finished_at: %DateTime{}, error: error} =
             Repo.get!(Run, stuck.id)

    assert error =~ "abandoned"
    assert Repo.get!(Run, live.id).outcome == "running"
    assert Repo.get!(Run, done.id).outcome == "ok"
  end

  test "closes running runs started before a cutoff" do
    stuck = run!("running", hours_ago(3))
    live = run!("running", hours_ago(0))

    assert %{closed: [id]} =
             Derivations.close_abandoned([started_before: hours_ago(1)], apply: true)

    assert id == stuck.id
    assert Repo.get!(Run, live.id).outcome == "running"
  end

  test "a dry run reports what it would close and changes nothing" do
    stuck = run!("running", hours_ago(3))

    assert %{closed: [id], applied: false} = Derivations.close_abandoned(ids: [stuck.id])
    assert id == stuck.id
    assert Repo.get!(Run, stuck.id).outcome == "running"
  end

  test "names the runs to close, so no live run is closed by accident" do
    assert_raise ArgumentError, fn -> Derivations.close_abandoned([], apply: true) end
  end

  test "Release prints what it closed" do
    stuck = run!("running", hours_ago(3))

    out =
      capture_io(fn ->
        Release.close_abandoned_derivation_runs([ids: [stuck.id]], apply: true)
      end)

    assert out =~ "##{stuck.id}"
    assert out =~ "abandoned"
    assert Repo.get!(Run, stuck.id).outcome == "abandoned"
  end
end
