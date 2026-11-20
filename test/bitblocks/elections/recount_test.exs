defmodule Bitblocks.Elections.RecountTest do
  @moduledoc """
  The observer's recount (https://github.com/afomi/bitblocks/issues/138): the
  single-file tool at `priv/static/elections/recount.py`, served at
  `/elections/recount.py`, run on an archive `Archive.build/2` writes. It reads
  only the files, with no network call, and must agree with
  `Bitblocks.Elections.Count` on every published vector.

  Skipped when `python3` isn't on PATH; CI installs it.
  """
  use Bitblocks.DataCase, async: false

  import Bitblocks.ElectionFixtures

  alias Bitblocks.Elections.Archive

  @python System.find_executable("python3")
  if is_nil(@python), do: @moduletag(skip: "python3 is not on PATH")

  @moduletag :tmp_dir

  defp tool, do: Application.app_dir(:bitblocks, "priv/static/elections/recount.py")

  defp vectors, do: Application.app_dir(:bitblocks, "priv/data/interop/election_count_v0.json")

  # -I: isolated, so nothing in the archive folder or the environment loads.
  defp recount(args) do
    System.cmd(@python || "python3", ["-I", tool() | args], stderr_to_stdout: true)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # Rewrites MANIFEST.sha256 for the files now in `dir`, as a forger would,
  # and returns its new sha256.
  defp reseal(dir) do
    manifest =
      dir
      |> Path.join("**")
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, dir))
      |> Enum.reject(&(&1 == "MANIFEST.sha256"))
      |> Enum.sort()
      |> Enum.map(&"#{sha256(File.read!(Path.join(dir, &1)))}  #{&1}\n")
      |> Enum.join()

    File.write!(Path.join(dir, "MANIFEST.sha256"), manifest)
    sha256(manifest)
  end

  setup %{tmp_dir: tmp} do
    s = scenario()
    dir = Path.join(tmp, "archive")
    {:ok, archive} = Archive.build(s.election, dir)
    %{s: s, dir: dir, archive: archive}
  end

  test "a good archive matches the published result", %{s: s, dir: dir, archive: archive} do
    {out, status} = recount([dir, "--archive-sha256", archive.archive_sha256])

    assert status == 0, out
    assert out =~ "Matches the published result."
    refute out =~ "Does not match"

    # Every ballot, counted or with the rule it failed, then the tally.
    t = s.txids
    assert out =~ ~r/counted +#{t.second} +height 13/
    assert out =~ ~r/counted +#{t.two} +height 15/
    assert out =~ "#{t.first}  height 12  #{s.one.address}  replaced: replaced by #{t.second}"
    assert out =~ "#{t.early}  height 11  #{s.one.address}  before_open"
    assert out =~ "#{t.outsider}  height 13  #{s.outsider.address}  not_on_roll"
    assert out =~ "#{t.unsigned}  height 14  no signer  no_signature"
    assert out =~ "#{t.late}  height 16  #{s.three.address}  after_close"
    assert out =~ "#{t.orphaned}  unconfirmed  #{s.three.address}  unconfirmed"
    assert out =~ ~r/alice +0\n +bob +1\n +carol +2\n/
    assert out =~ "Winners: carol, bob"
    assert out =~ "signed by #{s.admin.address}"

    # The test chain's easy targets are named, not hidden.
    assert out =~ "this is a test chain"
  end

  test "the result record's tx, signed by the administrator, matches too",
       %{s: s, dir: dir, archive: archive, tmp_dir: tmp} do
    result_tx =
      tx([
        output(
          map_fields("result_v1", [
            {"election", s.election},
            {"archive_sha256", archive.archive_sha256},
            {"closes_at_height", "15"},
            {"close_block_hash", archive.close_block_hash}
          ]),
          s.admin
        )
      ])

    path = Path.join(tmp, "result.hex")
    File.write!(path, Base.encode16(result_tx, case: :lower))

    {out, status} = recount([dir, "--result-tx", path])
    assert status == 0, out
    assert out =~ "match count.json and the result record"
    assert out =~ "The result record is tx #{txid(result_tx)}"

    # The same record from someone else's key is refused.
    forged =
      tx([
        output(
          map_fields("result_v1", [
            {"election", s.election},
            {"archive_sha256", archive.archive_sha256},
            {"closes_at_height", "15"},
            {"close_block_hash", archive.close_block_hash}
          ]),
          s.outsider
        )
      ])

    File.write!(path, forged)
    {out, status} = recount([dir, "--result-tx", path])
    assert status == 1

    assert out =~
             "the result is signed by #{s.outsider.address}, not the election's administrator"
  end

  test "a changed byte names the file and the tx, and prints no tally",
       %{s: s, dir: dir, archive: archive} do
    file = Path.join(dir, "txs/#{s.txids.second}.bin")
    bytes = File.read!(file)
    <<head::binary-size(byte_size(bytes) - 10), byte, rest::binary>> = bytes
    File.write!(file, <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>)

    {out, status} = recount([dir, "--archive-sha256", archive.archive_sha256])

    assert status == 1
    assert out =~ "txs/#{s.txids.second}.bin doesn't match MANIFEST.sha256"
    assert out =~ "tx #{s.txids.second}: txs/#{s.txids.second}.bin hashes to"
    assert out =~ "No tally is printed"
    refute out =~ "Tally"
    refute out =~ "Matches the published result"
  end

  test "a missing proof fails, even with the manifest rewritten to hide it",
       %{s: s, dir: dir, archive: archive} do
    File.rm!(Path.join(dir, "proofs/#{s.txids.two}.bump"))

    {out, status} = recount([dir, "--archive-sha256", archive.archive_sha256])
    assert status == 1
    assert out =~ "proofs/#{s.txids.two}.bump is listed in MANIFEST.sha256 but missing"

    # A forger who also rewrites the manifest no longer matches the result
    # record; given the new hash, the proof is still missing.
    forged = reseal(dir)
    {out, status} = recount([dir, "--archive-sha256", archive.archive_sha256])
    assert status == 1
    assert out =~ "MANIFEST.sha256 hashes to #{forged}, but the result record's archive_sha256"

    {out, status} = recount([dir, "--archive-sha256", forged])
    assert status == 1
    assert out =~ "tx #{s.txids.two}: its proof proofs/#{s.txids.two}.bump is missing"
    refute out =~ "Matches the published result"
  end

  test "a broken header chain fails, naming the height", %{dir: dir} do
    file = Path.join(dir, "headers.bin")
    headers = for <<h::binary-80 <- File.read!(file)>>, do: h
    # Heights 9..21: drop 13, so 14 sits where 13 was and names a parent
    # the header below it isn't.
    {left, [_dropped | right]} = Enum.split(headers, 4)
    File.write!(file, IO.iodata_to_binary(left ++ right))

    {out, status} = recount([dir, "--archive-sha256", reseal(dir)])

    assert status == 1
    assert out =~ "headers.bin: the header at height 13 doesn't name the one at height 12"
    assert out =~ "the headers don't chain"
    assert out =~ "No tally is printed"
  end

  test "a tally changed in count.json is caught by the recount", %{dir: dir} do
    file = Path.join(dir, "count.json")
    count = Jason.decode!(File.read!(file))
    count = put_in(count, ["result", "winners"], ["alice", "bob"])
    File.write!(file, Archive.json(count))

    {out, status} = recount([dir, "--archive-sha256", reseal(dir)])
    assert status == 1

    assert out =~
             ~s(count.json: its result winners is ["alice", "bob"], but the recount gives ["carol", "bob"])
  end

  test "refuses to run without the result record's archive_sha256", %{dir: dir} do
    {out, status} = recount([dir])
    assert status == 2
    assert out =~ "Give --archive-sha256"
  end

  test "agrees with Count on every published vector" do
    {out, status} = recount(["--self-test", vectors()])
    assert status == 0, out
    assert out =~ ~r/All \d+ vectors in election_count_v0.json match/
  end
end
