defmodule Bitblocks.ElectionsTest do
  @moduledoc """
  An election gathered from our index and counted live
  (`docs/ELECTION_DOGFOOD.md`). The chain is mined in the test
  (`ElectionFixtures.scenario/1`), with every record signed by a generated key.
  """
  use Bitblocks.DataCase, async: false

  import Bitblocks.ElectionFixtures

  alias Bitblocks.{Elections, Projections, Repo}
  alias Bitblocks.Chain.Block
  alias Bitblocks.TipLane.{Lane, LaneBlock}

  setup do
    %{s: scenario()}
  end

  describe "gather/2" do
    test "finds the election, its roll and its ballots, in chain order", %{s: s} do
      assert {:ok, g} = Elections.gather(s.election)

      assert g.administrator == s.admin.address
      assert g.election_record.height == 10
      assert g.election_record.input["election"] == s.election
      assert g.election_record.input["height"] == 10
      assert g.roll.outpoint == s.roll
      assert g.roll.height == 9

      assert g.roll.input == %{
               "members" => Enum.sort([s.one.address, s.two.address, s.three.address]),
               "height" => 9
             }

      t = s.txids

      assert Enum.map(g.ballots, & &1.txid) ==
               [t.early, t.first, t.second, t.outsider, t.unsigned, t.two, t.late, t.orphaned]

      refute t.other in Enum.map(g.ballots, & &1.txid)

      second = Enum.find(g.ballots, &(&1.txid == t.second))
      assert second.input["height"] == 13
      assert second.input["position"] == 1
      assert second.input["signer"] == s.one.address
      assert second.input["choices"] == ["carol"]

      outsider = Enum.find(g.ballots, &(&1.txid == t.outsider))
      assert outsider.input["position"] == 2

      orphaned = Enum.find(g.ballots, &(&1.txid == t.orphaned))
      assert orphaned.input["height"] == nil
      assert orphaned.input["position"] == nil
      assert orphaned.proof == nil
    end

    test "says how far our index reaches", %{s: s} do
      assert {:ok, %{coverage: coverage, window: window}} = Elections.gather(s.election)

      assert window == %{
               from_height: 10,
               opens_at_height: 12,
               closes_at_height: 15,
               to_height: 21
             }

      assert coverage == %{
               complete_through: 21,
               tip_lane_through_height: nil,
               projection_id: nil,
               covered_through: 21,
               tip_height: 21,
               current_to: 21,
               complete: true
             }
    end

    test "reads ballots only as far as the index covers", %{s: s} do
      # Blocks above 13 left for the sync.
      Repo.update_all(from(b in Block, where: b.height > 13), set: [sync_state: "header_only"])

      assert {:ok, g} = Elections.gather(s.election)
      assert g.coverage.covered_through == 13
      assert g.coverage.complete == false
      assert Enum.all?(g.ballots, &(&1.height in [11, 12, 13]))
    end

    test "counts a projection's tip lane in the coverage", %{s: s} do
      Repo.update_all(from(b in Block, where: b.height > 13), set: [sync_state: "header_only"])

      {:ok, projection} =
        Projections.create(%{
          tenant: "pba",
          name: "election",
          filter: %{"protocols" => ["MAP"]},
          from_height: 10
        })

      Repo.insert!(%Lane{projection_id: projection.id, from_height: 10, status: "running"})

      for %{height: h, hash: hash} <- Repo.all(from(b in Block, where: b.height > 13)) do
        Repo.insert!(%LaneBlock{
          projection_id: projection.id,
          height: h,
          block_hash: hash,
          status: "read"
        })
      end

      assert {:ok, g} = Elections.gather(s.election, projection: projection.id)
      assert g.coverage.complete_through == 13
      assert g.coverage.tip_lane_through_height == 21
      assert g.coverage.covered_through == 21
      assert g.coverage.projection_id == projection.id
      assert length(g.ballots) == 8
    end

    test "refuses what isn't an election it can read", %{s: s} do
      assert Elections.gather("nope") == {:error, :invalid_outpoint}
      assert Elections.gather("#{random_hash()}.0") == {:error, {:not_found, :election}}

      [roll_txid, _] = String.split(s.roll, ".")

      assert {:error, {:not_a_record, :election, {:wrong_type, :roll}}} =
               Elections.gather("#{roll_txid}.1")

      assert {:error, {:not_a_record, :election, :no_map}} = Elections.gather("#{roll_txid}.0")
    end

    test "a roll that doesn't match its hash, or another key's roll, is refused", %{s: s} do
      admin = s.admin
      content = roll_file([s.one.address])
      roll_tx = tx([output(roll_fields(content), admin)])
      wrong = String.duplicate("0", 64)
      election_tx = tx([output(election_fields({"#{txid(roll_tx)}.0", wrong}), admin)])

      stranger = key()
      roll_tx2 = tx([output(roll_fields(content), stranger)])
      sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      election_tx2 = tx([output(election_fields({"#{txid(roll_tx2)}.0", sha}), admin)])

      # A block above the chain, so each tx is proven in it.
      block(22, Repo.get_by!(Block, height: 21).hash, [
        roll_tx,
        election_tx,
        roll_tx2,
        election_tx2
      ])

      assert Elections.gather("#{txid(election_tx)}.0") == {:error, :roll_sha256_mismatch}

      assert Elections.gather("#{txid(election_tx2)}.0") ==
               {:error, :roll_not_signed_by_administrator}
    end

    test "a scan past the bound is refused, not cut short", %{s: s} do
      previous = Application.get_env(:bitblocks, :election_max_scanned)
      Application.put_env(:bitblocks, :election_max_scanned, 3)

      try do
        assert Elections.gather(s.election) == {:error, {:too_many_candidates, 3}}
      after
        if previous,
          do: Application.put_env(:bitblocks, :election_max_scanned, previous),
          else: Application.delete_env(:bitblocks, :election_max_scanned)
      end
    end
  end

  describe "count_now/2" do
    test "counts every ballot, with the rule each one failed", %{s: s} do
      assert {:ok, answer} = Elections.count_now(s.election)
      t = s.txids

      rules = Map.new(answer.count.ballots, &{&1.txid, {&1.counted, &1.rule, &1.replaced_by}})

      assert rules[t.early] == {false, :before_open, nil}
      assert rules[t.first] == {false, :replaced, t.second}
      assert rules[t.second] == {true, nil, nil}
      assert rules[t.outsider] == {false, :not_on_roll, nil}
      assert rules[t.unsigned] == {false, :no_signature, nil}
      assert rules[t.two] == {true, nil, nil}
      assert rules[t.late] == {false, :after_close, nil}
      assert rules[t.orphaned] == {false, :unconfirmed, nil}

      assert answer.count.tally == [
               %{candidate: "alice", votes: 0},
               %{candidate: "bob", votes: 1},
               %{candidate: "carol", votes: 2}
             ]

      assert answer.count.winners == ["carol", "bob"]
      assert answer.final
      assert answer.current_to == %{height: 21, hash: Repo.get_by!(Block, height: 21).hash}
      assert answer.close_block_hash == Repo.get_by!(Block, height: 15).hash
    end

    test "while voting is open, the count is current to the block we cover", %{s: s} do
      Repo.update_all(from(b in Block, where: b.height > 13), set: [sync_state: "header_only"])

      assert {:ok, answer} = Elections.count_now(s.election)
      assert answer.current_to.height == 13
      refute answer.final
      assert answer.count.tally |> Enum.map(& &1.votes) == [0, 0, 1]
    end

    test "a reorg that drops a ballot's block drops it from the count", %{s: s} do
      # Block 15, which held `two`, is replaced; the tx row keeps the old hash.
      replacement = random_hash()
      Repo.update_all(from(b in Block, where: b.height == 15), set: [hash: replacement])
      Repo.update_all(from(b in Block, where: b.height == 16), set: [prevblockhash: replacement])

      assert {:ok, answer} = Elections.count_now(s.election)
      two = Enum.find(answer.count.ballots, &(&1.txid == s.txids.two))
      assert two.rule == :unconfirmed
      assert answer.count.winners == ["carol"]
      assert answer.close_block_hash == replacement
    end
  end
end
