defmodule Bitblocks.Elections.ArchiveTest do
  @moduledoc """
  The election archive (`docs/ELECTION_DOGFOOD.md`, "The archive"): static
  files an observer can recount from with no network call. The checks here
  read only the written files, as the recount tool will
  (https://github.com/afomi/bitblocks/issues/138).
  """
  use Bitblocks.DataCase, async: false

  import Bitblocks.ElectionFixtures

  alias Bitblocks.{Elections, Release, Repo}
  alias Bitblocks.Chain.{Beef, Block}
  alias Bitblocks.Elections.{Archive, Count, Records}

  @moduletag :tmp_dir

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))

  defp display(hash),
    do:
      hash
      |> :binary.bin_to_list()
      |> Enum.reverse()
      |> :binary.list_to_bin()
      |> Base.encode16(case: :lower)

  defp files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Map.new(&{Path.relative_to(&1, dir), File.read!(&1)})
  end

  describe "with the close six blocks deep" do
    setup do
      %{s: scenario()}
    end

    test "writes the layout, and the manifest's sha256 is archive_sha256", %{s: s, tmp_dir: tmp} do
      dir = Path.join(tmp, "a")
      assert {:ok, archive} = Archive.build(s.election, dir)

      written = files(dir)
      manifest = written["MANIFEST.sha256"]
      assert archive.archive_sha256 == sha256(manifest)

      lines = String.split(manifest, "\n", trim: true)

      listed =
        Map.new(lines, fn line ->
          [hash, path] = String.split(line, "  ")
          {path, hash}
        end)

      # Every file but the manifest is listed, with its own hash, sorted by path.
      assert Map.keys(listed) |> Enum.sort() ==
               Map.keys(written) |> List.delete("MANIFEST.sha256") |> Enum.sort()

      assert Enum.map(lines, &(String.split(&1, "  ") |> List.last())) ==
               Enum.sort(Map.keys(listed))

      for {path, hash} <- listed, do: assert(sha256(written[path]) == hash)

      t = s.txids
      record_txids = [txid(s.roll_tx), txid(s.election_tx)] ++ Map.values(Map.delete(t, :other))

      for txid <- record_txids do
        assert display(sha256d(written["txs/#{txid}.bin"])) == txid
      end

      refute Map.has_key?(written, "txs/#{t.other}.bin")
      refute Map.has_key?(written, "proofs/#{t.orphaned}.bump")
      assert written["roll.json"] == s.roll_content
    end

    test "is byte-identical when built again", %{s: s, tmp_dir: tmp} do
      assert {:ok, one} = Archive.build(s.election, Path.join(tmp, "one"))
      assert {:ok, two} = Archive.build(s.election, Path.join(tmp, "two"))

      assert one.archive_sha256 == two.archive_sha256
      assert files(Path.join(tmp, "one")) == files(Path.join(tmp, "two"))

      # Writing over an earlier copy of itself is a rebuild, not a clash.
      assert {:ok, %{archive_sha256: same}} = Archive.build(s.election, Path.join(tmp, "one"))
      assert same == one.archive_sha256
    end

    test "can be checked from its files alone", %{s: s, tmp_dir: tmp} do
      dir = Path.join(tmp, "check")
      assert {:ok, _} = Archive.build(s.election, dir)
      written = files(dir)
      index = Jason.decode!(written["archive.json"])

      # The headers chain, from the roll's block to closes + 6.
      %{"from_height" => from, "to_height" => to, "count" => n} = index["headers"]
      assert {from, to, n} == {9, 21, 13}
      headers = for <<h::binary-80 <- written["headers.bin"]>>, do: h
      assert length(headers) == n

      hashes = Enum.map(headers, &sha256d/1)

      for {header, below} <- Enum.zip(Enum.drop(headers, 1), hashes) do
        <<_version::binary-4, prev::binary-32, _::binary>> = header
        assert prev == below
      end

      roots =
        headers
        |> Enum.with_index(from)
        |> Map.new(fn {<<_::binary-36, root::binary-32, _::binary>>, h} -> {h, display(root)} end)

      # Each confirmed record's BUMP climbs from its txid to its header's root,
      # at the offset the record gives as its position.
      for %{"txid" => txid, "height" => height, "position" => position, "proof" => proof} <-
            index["records"],
          proof do
        {:ok, bump, ""} = Beef.parse_bump(written[proof])
        assert bump.height == height
        assert {:ok, root} = Beef.root(bump, txid)
        assert root == roots[height]
        assert Enum.find(hd(bump.path), & &1.txid).offset == position
      end

      # The records re-read from the tx bytes give the count's input.
      count = Jason.decode!(written["count.json"])
      ballots = count["input"]["ballots"]

      for %{"txid" => txid, "signer" => signer, "choices" => choices} <- ballots do
        record = Enum.find(index["records"], &(&1["txid"] == txid))
        {:ok, parsed} = Records.parse_output(written["txs/#{txid}.bin"], record["vout"])
        assert parsed.signer == signer
        assert parsed.fields["choices"] == choices
      end

      assert sha256(written["roll.json"]) == index["roll"]["sha256"]

      # And the rule, run on that input, gives the result written beside it.
      input = count["input"]

      {:ok, result} =
        Count.count(input["election"], input["roll"], input["ballots"],
          close_block_hash: input["close_block_hash"]
        )

      assert Archive.json(result) == Archive.json(count["result"])
      assert count["result"]["winners"] == ["carol", "bob"]
      assert input["close_block_hash"] == Repo.get_by!(Block, height: 15).hash
    end

    test "count.json is the live count's answer", %{s: s, tmp_dir: tmp} do
      dir = Path.join(tmp, "same")
      assert {:ok, _} = Archive.build(s.election, dir)
      assert {:ok, live} = Elections.count_now(s.election)

      assert Jason.decode!(File.read!(Path.join(dir, "count.json")))["result"] ==
               Jason.decode!(Archive.json(live.count))
    end

    test "won't write over other files", %{s: s, tmp_dir: tmp} do
      dir = Path.join(tmp, "busy")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "notes.txt"), "mine")

      assert {:error, {:dir_not_empty, ^dir, ["notes.txt"]}} = Archive.build(s.election, dir)
    end

    test "Release.build_election_archive/3 is a dry run until apply", %{s: s, tmp_dir: tmp} do
      dir = Path.join(tmp, "release")

      assert {:ok, dry} = Release.build_election_archive(s.election, dir)
      assert dry.dry_run
      refute File.exists?(dir)
      assert Enum.any?(dry.files, &(&1.path == "MANIFEST.sha256"))

      assert {:ok, wet} = Release.build_election_archive(s.election, dir, apply: true)
      refute wet.dry_run
      assert wet.archive_sha256 == dry.archive_sha256
      assert wet.winners == ["carol", "bob"]
      assert sha256(File.read!(Path.join(dir, "MANIFEST.sha256"))) == wet.archive_sha256
    end

    test "Release.election_count/1 gives the live count", %{s: s} do
      assert {:ok, %{count: %{winners: ["carol", "bob"]}, final: true}} =
               Release.election_count(s.election)
    end
  end

  test "is refused until the close is six blocks deep, naming how many remain", %{tmp_dir: tmp} do
    s = scenario(through: 18)
    dir = Path.join(tmp, "early")

    assert Archive.build(s.election, dir) ==
             {:error,
              {:too_shallow,
               %{closes_at_height: 15, needed_height: 21, tip_height: 18, blocks_remaining: 3}}}

    refute File.exists?(dir)
  end

  test "is refused while our index doesn't cover the window", %{tmp_dir: tmp} do
    s = scenario()
    Repo.update_all(from(b in Block, where: b.height > 19), set: [sync_state: "header_only"])

    assert Archive.build(s.election, Path.join(tmp, "x")) ==
             {:error, {:not_covered, %{needed_height: 21, covered_through: 19}}}
  end
end
