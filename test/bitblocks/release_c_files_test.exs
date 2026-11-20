defmodule Bitblocks.ReleaseCFilesTest do
  # Release.backfill_c_files/3 (https://github.com/afomi/bitblocks/issues/147):
  # a dry run by default that says what it would write, then the apply.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.CFiles.CFile
  alias Bitblocks.Release

  @txid "7e5011d81d01c67e81ab9a50ab3077bb62b340d1b50592931e4b52afa7198e65"
  @hex "test/fixtures/bob/#{@txid}.hex" |> File.read!() |> String.trim()

  defp quietly(fun) do
    output = capture_io(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    {result, output}
  end

  test "a dry run prints what it would write; the apply writes it" do
    transaction_fixture(%{txid: @txid, raw: @hex, protocols: ["B://"], block_height: 500})

    {dry, output} = quietly(fn -> Release.backfill_c_files(0, 1_000, pause_ms: 0) end)
    refute dry.applied
    assert output =~ "1 B:// file row(s) to write"
    assert Repo.aggregate(CFile, :count) == 0

    {applied, output} =
      quietly(fn -> Release.backfill_c_files(0, 1_000, apply: true, pause_ms: 0) end)

    assert applied.applied
    assert output =~ "1 B:// file row(s) written"
    assert output =~ "0 row(s) missing or changed in the range"
    assert Repo.aggregate(CFile, :count) == 1
  end

  test "c_files_status names the rows by kind and the BCat heads not indexed" do
    Repo.insert!(%Bitblocks.CFiles.Miss{
      txid: String.duplicate("ef", 32),
      block_height: 700,
      reason: "missing_chunks",
      missing_chunks: [String.duplicate("01", 32)],
      version: 2
    })

    {status, output} = quietly(fn -> Release.c_files_status() end)

    assert status.misses_by_reason == %{"missing_chunks" => 1}
    assert output =~ "0 B:// row(s), 0 BCat row(s)"
    assert output =~ "BCat heads not indexed: 1 missing_chunks"
    assert output =~ "1 chunk(s) missing"
  end
end
