defmodule BitblocksWeb.Api.CFileControllerTest do
  # GET /api/v1/c/:sha256 (https://github.com/afomi/bitblocks/issues/147):
  # the stored outputs that carry a file, by its C:// address.
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.CFiles
  alias Bitblocks.Chain.Block

  @txid "7e5011d81d01c67e81ab9a50ab3077bb62b340d1b50592931e4b52afa7198e65"
  @hex "test/fixtures/bob/#{@txid}.hex" |> File.read!() |> String.trim()
  @sha "HAHAHAHA" |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  test "lists every stored copy, oldest first, with the file URL and the index's reach", %{
    conn: conn
  } do
    tx =
      transaction_fixture(%{txid: @txid, raw: @hex, protocols: ["B://"], block_height: 594_000})

    CFiles.index(tx, %Block{height: 594_000})

    body = conn |> get(~p"/api/v1/c/#{@sha}") |> json_response(200)

    assert %{
             "data" => %{
               "sha256" => @sha,
               "c_url" => "c://" <> @sha,
               "file_url" => "/c/" <> @sha,
               "locations" => [
                 %{
                   "txid" => @txid,
                   "vout" => vout,
                   "block_height" => 594_000,
                   "media_type" => "text/plain",
                   "filename" => "twetch_twtext_1565131423556.txt",
                   "size" => 8,
                   "b_url" => "/b/" <> @txid
                 }
               ]
             },
             "meta" => %{"indexed_through_height" => nil, "source" => "c_files", "version" => 2}
           } = body

    assert is_integer(vout)
    assert [%{"kind" => "b", "chunks" => nil, "bcat_url" => nil}] = body["data"]["locations"]
  end

  test "lists a BCat file with its kind, head, chunks and where it is served", %{conn: conn} do
    import Bitblocks.BcatFixtures

    chunks = [chunk("big "), chunk("file")]
    {txid, hex} = head(chunks)
    transaction_fixture(%{txid: txid, raw: hex, protocols: ["BCat"], block_height: 650_000})
    Enum.each(chunks, &Bitblocks.OrdinalFixtures.publish/1)
    {:ok, _row} = CFiles.index_bcat(txid, 650_000)

    sha = "big file" |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    body = conn |> get(~p"/api/v1/c/#{sha}") |> json_response(200)

    assert %{
             "locations" => [
               %{
                 "kind" => "bcat",
                 "txid" => ^txid,
                 "chunks" => 2,
                 "size" => 8,
                 "b_url" => nil,
                 "bcat_url" => "/content/bcat/" <> ^txid
               }
             ]
           } = body["data"]
  end

  test "a miss counts the BCat heads that couldn't be assembled", %{conn: conn} do
    Bitblocks.Repo.insert!(%Bitblocks.CFiles.Miss{
      txid: String.duplicate("cd", 32),
      reason: "missing_chunks",
      version: 2
    })

    body = conn |> get(~p"/api/v1/c/#{String.duplicate("0", 64)}") |> json_response(404)

    assert body["meta"]["bcat_unassembled"] == 1
    assert body["message"] =~ "One BCat file we know of couldn't be assembled"
  end

  test "an address not in the index is a 404 that says how far the index reaches", %{conn: conn} do
    body = conn |> get(~p"/api/v1/c/#{String.duplicate("0", 64)}") |> json_response(404)

    assert %{"error" => "not_indexed", "meta" => %{"indexed_through_height" => nil}} = body
  end

  test "a malformed address is a 400", %{conn: conn} do
    assert %{"error" => error} = conn |> get(~p"/api/v1/c/xyz") |> json_response(400)
    assert error =~ "64 hex characters"
  end
end
