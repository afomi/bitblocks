defmodule Bitblocks.Bitcom.FilesTest do
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.Bitcom.Files

  # A real mainnet B:// + MAP tx (Twetch, 2019); see test/bitblocks/bob_test.exs.
  @txid "7e5011d81d01c67e81ab9a50ab3077bb62b340d1b50592931e4b52afa7198e65"
  @hex "test/fixtures/bob/#{@txid}.hex" |> File.read!() |> String.trim()

  defp b_row(attrs) do
    transaction_fixture(Map.merge(%{protocols: ["B://", "MAP"], block_height: 594_000}, attrs))
  end

  test "lists each B:// file with its name, type, size and C:// address" do
    b_row(%{txid: @txid, raw: @hex})

    assert {:ok, %{files: [file], before: nil}} = Files.list()

    assert file == %{
             txid: @txid,
             block_height: 594_000,
             parsed: true,
             filename: "twetch_twtext_1565131423556.txt",
             media_type: "text/plain",
             encoding: "text",
             size: 8,
             sha256: :crypto.hash(:sha256, "HAHAHAHA") |> Base.encode16(case: :lower)
           }
  end

  test "a tagged tx whose bytes we can't read is listed, unparsed; untagged txs aren't" do
    b_row(%{raw: "not hex"})
    transaction_fixture(%{protocols: ["MAP"], raw: @hex})

    assert {:ok, %{files: [%{parsed: false, sha256: nil}]}} = Files.list()
  end

  test "pages newest stored first, with before" do
    older = b_row(%{txid: @txid, raw: @hex})
    newer = b_row(%{raw: "not hex"})

    assert {:ok, %{files: [%{txid: first}], before: before}} = Files.list(per_page: 1)
    assert first == newer.txid

    assert {:ok, %{files: [%{txid: second}], before: nil}} =
             Files.list(per_page: 1, before: before)

    assert second == older.txid
  end
end
