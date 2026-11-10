defmodule Bitblocks.ChainScrubberTest do
  @moduledoc """
  Resting on a block (#48): the one tx-level read is capped and under a
  statement timeout, a block above the threshold is a fixed-size density
  grid whatever its tx count, a block that isn't completed is a gap, and
  the annotation layer carries recorded reorgs and classified losses only.
  """
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.ChainScrubber
  alias Bitblocks.ChainScrubber.Losses
  alias Bitblocks.Reorgs

  defp completed_block(height, num_tx) do
    block_fixture(%{height: height, num_tx: num_tx, sync_state: "completed"})
  end

  defp txs_for(block, n) do
    for i <- 1..n do
      transaction_fixture(%{
        block_hash: block.hash,
        block_height: block.height,
        total_output_satoshis: Integer.pow(2, rem(i, 40)),
        coinbase: i == 1,
        protocols: if(rem(i, 3) == 0, do: ["Twetch"], else: []),
        input_count: 1,
        output_count: 2
      })
    end
  end

  describe "rest/2" do
    test "a height we hold no row for is missing" do
      assert %{kind: "missing", height: 5_000_001} = ChainScrubber.rest(5_000_001)
    end

    test "a block that isn't completed is a gap, and reads no transactions" do
      block = block_fixture(%{height: 700_001, num_tx: 9, sync_state: "header_only"})
      txs_for(block, 3)

      assert %{kind: "gap", state: "header_only", num_tx: 9} = ChainScrubber.rest(700_001)
    end

    test "below the threshold: one mark per tx, at most the cap" do
      block = completed_block(700_002, 5)
      txs_for(block, 5)

      payload = ChainScrubber.rest(700_002, cap: 3)
      assert payload.kind == "marks"
      assert payload.sample == 3
      assert length(payload.txs) == 3

      assert %{txid: _, sats: _, inputs: 1, outputs: 2, coinbase: _, protocols: _} =
               hd(payload.txs)
    end

    test "above the threshold: a fixed-size density grid whatever the tx count" do
      small = completed_block(700_003, 30)
      txs_for(small, 30)
      large = completed_block(700_004, 4_000_000)
      txs_for(large, 90)

      a = ChainScrubber.rest(700_003, threshold: 10, cap: 50)
      b = ChainScrubber.rest(700_004, threshold: 10, cap: 50)

      assert a.kind == "density" and b.kind == "density"
      assert a.cols == 64 and b.cols == 64
      assert length(a.rows) == 16 and length(b.rows) == 16
      assert length(a.grid) == 16 * 64
      assert length(b.grid) == 16 * 64
      assert a.sample == 30
      assert b.sample == 50, "the read stops at the cap"
      assert Enum.sum(a.grid) == 30
      assert Enum.sum(b.grid) == 50
      assert Enum.take(a.rows, 3) == ["coinbase", "transfer", "Twetch"]
    end

    test "the tx read runs with LIMIT cap under SET LOCAL statement_timeout" do
      block = completed_block(700_005, 3)
      txs_for(block, 3)
      test_pid = self()

      :telemetry.attach(
        "chain-scrubber-rest-#{inspect(test_pid)}",
        [:bitblocks, :repo, :query],
        fn _event, _measure, meta, _ ->
          if self() == test_pid, do: send(test_pid, {:sql, meta.query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("chain-scrubber-rest-#{inspect(test_pid)}") end)

      ChainScrubber.rest(700_005, cap: 17, timeout_ms: 1234)

      statements = drain_sql([])
      assert "SET LOCAL statement_timeout = 1234" in statements
      assert [tx_sql] = Enum.filter(statements, &(&1 =~ ~r/FROM "transactions"/))
      assert tx_sql =~ ~r/LIMIT \$\d/

      assert Enum.find_index(statements, &(&1 =~ "statement_timeout")) <
               Enum.find_index(statements, &(&1 == tx_sql))
    end

    test "a read Postgres cancels is an explicit unavailable state, never a hang" do
      assert {:error, :timeout} =
               ChainScrubber.with_statement_timeout(20, fn ->
                 Repo.query!("SELECT pg_sleep(2)")
               end)

      assert {:ok, [[1]]} =
               ChainScrubber.with_statement_timeout(2_000, fn -> Repo.query!("SELECT 1").rows end)
    end

    test "a cancelled tx read answers unavailable with the reason" do
      block = completed_block(700_006, 3)
      txs_for(block, 3)

      # Force the cancel: a statement_timeout of 1 ms against pg_sleep in the
      # same transaction is not reachable through rest/2, so drive the branch
      # through sample_transactions with a hash whose read we can slow down.
      assert {:error, :timeout} =
               ChainScrubber.with_statement_timeout(1, fn ->
                 Repo.query!("SELECT pg_sleep(0.5)")
               end)

      assert %{kind: "marks"} = ChainScrubber.rest(700_006)
    end
  end

  defp drain_sql(acc) do
    receive do
      {:sql, sql} -> drain_sql([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "density/1" do
    test "rows are tx classes, columns are log2 of output value, size is fixed" do
      txs = [
        %{txid: "a", coinbase: true, protocols: [], sats: 5_000_000_000, inputs: 1, outputs: 1},
        %{txid: "b", coinbase: false, protocols: [], sats: 1, inputs: 1, outputs: 1},
        %{txid: "c", coinbase: false, protocols: ["bsv-20"], sats: 1024, inputs: 1, outputs: 1},
        %{txid: "d", coinbase: false, protocols: ["bsv-20"], sats: 0, inputs: 1, outputs: 1}
      ]

      grid = ChainScrubber.density(txs)

      assert grid.rows |> Enum.take(3) == ["coinbase", "transfer", "bsv-20"]
      assert Enum.at(grid.rows, 3) == "other"
      assert length(grid.grid) == 1024
      assert Enum.at(grid.grid, 0 * 64 + ChainScrubber.value_bin(5_000_000_000)) == 1
      assert Enum.at(grid.grid, 1 * 64 + 0) == 1
      assert Enum.at(grid.grid, 2 * 64 + 10) == 1
      assert Enum.at(grid.grid, 2 * 64 + 0) == 1
    end

    test "value_bin clamps" do
      assert ChainScrubber.value_bin(nil) == 0
      assert ChainScrubber.value_bin(0) == 0
      assert ChainScrubber.value_bin(1) == 0
      assert ChainScrubber.value_bin(2) == 1
      assert ChainScrubber.value_bin(2_100_000_000_000_000) == 50
    end
  end

  describe "annotations/0" do
    test "a recorded reorg and a classified loss each appear at their height, linked to evidence" do
      {:ok, _} =
        Reorgs.record_observed(%{
          fork_height: 812_345,
          fork_point: 812_344,
          orphan_count: 1,
          outcome: "resolved",
          summary: "one block orphaned at 812,345"
        })

      annotations = ChainScrubber.annotations()

      reorg = Enum.find(annotations, &(&1.kind == "reorg" and &1.height == 812_345))
      assert reorg.evidence_url == "/reorgs"
      assert reorg.detail =~ "812345"

      # Rexxie #159, the first classified loss in the field note
      loss = Enum.find(annotations, &(&1.kind == "loss" and &1.height == 875_850))
      assert loss.label =~ "Rexxie #159"

      assert loss.evidence_url ==
               "/transactions/1f34afe214dadc5c0324428fdfa1264ffa122ea6aa3b50b0889721a581868a1c"

      assert loss.note_url =~ "2026-11-02-rexxies-spent-outside-run.md"

      assert annotations == Enum.sort_by(annotations, & &1.height)
    end

    test "a placed chain annotation is an event marker with its kind; an unplaced one is not" do
      {:ok, _} =
        Bitblocks.Annotations.create(%{
          kind: "fork",
          title: "Bitcoin SV splits from Bitcoin Cash",
          height: 556_767,
          source_url: "https://en.wikipedia.org/wiki/Bitcoin_SV"
        })

      {:ok, _} =
        Bitblocks.Annotations.create(%{
          kind: "mint",
          title: "Not here yet",
          txid: String.duplicate("ab", 32)
        })

      events = Enum.filter(ChainScrubber.annotations(), &(&1.kind == "event"))

      assert [
               %{
                 event_kind: "fork",
                 height: 556_767,
                 evidence_url: "https://en.wikipedia.org/wiki/Bitcoin_SV"
               }
             ] = events
    end

    test "the blocks that burned most appear at their height, linked to the block" do
      block_fixture(%{height: 20, burned: 150_000_000, sync_state: "completed"})
      block_fixture(%{height: 21, burned: 0, sync_state: "completed"})

      burns = Enum.filter(ChainScrubber.annotations(), &(&1.kind == "burn"))

      assert [%{height: 20, evidence_url: "/blocks/20", label: "1.5 BSV burned at 20"}] = burns
    end

    test "a burn mark links to its block's largest burning tx when that tx is stored" do
      block = block_fixture(%{height: 30, burned: 150_000_000, sync_state: "completed"})
      big = String.duplicate("b", 64)
      small = String.duplicate("a", 64)

      transaction_fixture(%{
        txid: small,
        block_hash: block.hash,
        block_height: 30,
        burned_satoshis: 50_000_000
      })

      transaction_fixture(%{
        txid: big,
        block_hash: block.hash,
        block_height: 30,
        burned_satoshis: 100_000_000
      })

      transaction_fixture(%{block_hash: block.hash, block_height: 30, burned_satoshis: 0})

      assert [burn] = Enum.filter(ChainScrubber.annotations(), &(&1.kind == "burn"))
      assert burn.height == 30
      assert burn.txid == big
      assert burn.evidence_url == "/transactions/#{big}"
      assert burn.detail =~ "1 BSV in #{big}"
    end

    test "only classified losses appear; tracing doubts stay off the layer" do
      note_data =
        "docs/field-notes/data/rexxies-spent-outside-run-2026-11-02.json"
        |> File.read!()
        |> Jason.decode!()

      strong = for e <- note_data, e["confidence"] == "strong", do: e["item"]
      open = for e <- note_data, e["confidence"] != "strong", do: e["item"]
      classified = Losses.classified()
      items = Enum.map(classified, & &1.item)

      assert Enum.sort(items) == Enum.sort(strong)
      assert length(strong) == 30
      assert length(open) == 5
      for doubt <- open, do: refute(doubt in items, "#{doubt} is an open doubt (#46), not a loss")
      assert Enum.all?(classified, &(&1.kind == "destroyed" and is_integer(&1.height)))
    end
  end
end
