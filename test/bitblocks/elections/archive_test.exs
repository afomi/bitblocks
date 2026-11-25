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

      # Every file but the manifest and the three beside it is listed, with
      # its own hash, sorted by path.
      assert Archive.beside() == ["index.html", "recount.py", "recount.html"]

      assert Map.keys(listed) |> Enum.sort() ==
               Map.keys(written)
               |> Kernel.--(["MANIFEST.sha256" | Archive.beside()])
               |> Enum.sort()

      for path <- Archive.beside(), do: assert(Map.has_key?(written, path))

      assert Enum.sort(Enum.map(archive.files, & &1.path)) ==
               Enum.sort(["MANIFEST.sha256" | Map.keys(listed)])

      assert Enum.map(archive.beside, & &1.path) == Archive.beside()

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

    test "index.html shows count.json's tally and winners, and archive_sha256",
         %{s: s, tmp_dir: tmp} do
      dir = Path.join(tmp, "page")
      assert {:ok, archive} = Archive.build(s.election, dir)
      written = files(dir)
      page = written["index.html"]
      count = Jason.decode!(written["count.json"])

      assert page =~ "<h1>PBA Board 2026</h1>"
      assert page =~ ~s(id="archive-sha256")
      assert page =~ archive.archive_sha256
      assert page =~ "Result record not published yet."
      assert page =~ "Recount it yourself"
      assert page =~ ~s(href="recount.py")
      assert page =~ ~s(href="recount.html")
      assert page =~ "python3 -I recount.py . --archive-sha256 #{archive.archive_sha256}"

      # Each candidate's votes on the page are count.json's.
      for %{"candidate" => id, "votes" => votes} <- count["result"]["tally"] do
        [card] = Regex.run(~r/<li\s+id="candidate-#{id}".*?<\/li>/s, page)
        label = if votes == 1, do: "1 vote", else: "#{votes} votes"
        assert card =~ ~s(<span class="mono">#{label}</span>)
        assert card =~ "elected" == id in count["result"]["winners"]
      end

      [winners] = Regex.run(~r/<ol\s+id="winners".*?<\/ol>/s, page)
      names = Regex.scan(~r/<li>(.*?)<\/li>/, winners) |> Enum.map(&List.last/1)
      assert names == ["Carol", "Bob"]
      assert count["result"]["winners"] == ["carol", "bob"]

      # Self-contained: no script, and nothing fetched from anywhere.
      refute page =~ "<script"
      refute page =~ ~r/<link\b/
      refute page =~ ~r/\bsrc=/
      refute page =~ ~r/href="(https?:)?\/\//

      # The copies beside it are the published static files, byte for byte.
      static = &File.read!(Application.app_dir(:bitblocks, "priv/static/elections/#{&1}"))
      assert written["recount.py"] == static.("recount.py")
      assert written["recount.html"] == static.("recount.html")

      # archive.json names the three, and the manifest names none of them.
      assert Jason.decode!(written["archive.json"])["beside"]["files"] == Archive.beside()
      for path <- Archive.beside(), do: refute(written["MANIFEST.sha256"] =~ path)
    end

    test "the result record's txid shows on the page and leaves archive_sha256 alone",
         %{s: s, tmp_dir: tmp} do
      result_txid = String.duplicate("ab", 32)
      assert {:ok, bare} = Archive.plan(s.election)

      assert {:ok, named} =
               Archive.build(s.election, Path.join(tmp, "named"), result_txid: result_txid)

      assert named.archive_sha256 == bare.archive_sha256
      assert Enum.map(named.files, & &1.sha256) == Enum.map(bare.files, & &1.sha256)

      page = File.read!(Path.join([tmp, "named", "index.html"]))
      assert page =~ "The result record is transaction"
      assert page =~ result_txid
      refute page =~ "Result record not published yet."

      assert Archive.plan(s.election, result_txid: "not a txid") ==
               {:error, :invalid_result_txid}
    end

    test "the zip holds exactly the archive's files and the three beside them, the same each time",
         %{s: s, tmp_dir: tmp} do
      assert {:ok, built} = Archive.build(s.election, Path.join(tmp, "z"))
      assert {:ok, %{name: name, bytes: zip}} = Archive.zip(built)

      folder = Archive.folder(s.election)
      assert name == "#{folder}.zip"
      assert folder == "election-" <> String.replace(s.election, ".", "-")

      {:ok, entries} = :zip.unzip(zip, [:memory])
      unzipped = Map.new(entries, fn {path, bytes} -> {to_string(path), bytes} end)

      expected =
        Map.new(files(Path.join(tmp, "z")), fn {path, bytes} -> {"#{folder}/#{path}", bytes} end)

      assert unzipped == expected

      assert Enum.sort(Map.keys(unzipped)) ==
               Enum.sort(Enum.map(built.files ++ built.beside, &"#{folder}/#{&1.path}"))

      # A rebuild zips to the same bytes.
      assert {:ok, again} = Archive.build(s.election, Path.join(tmp, "z2"))
      assert {:ok, %{bytes: ^zip}} = Archive.zip(again)
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
