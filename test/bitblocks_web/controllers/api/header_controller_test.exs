defmodule BitblocksWeb.Api.HeaderControllerTest do
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.{Headers, HeaderVerifier}
  alias Bitblocks.RealHeaders

  @fixtures Path.expand("../../../support/fixtures/brc", __DIR__)

  defp headers_vector do
    @fixtures |> Path.join("headers_v1.json") |> File.read!() |> Jason.decode!()
  end

  defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))

  defp reverse(bytes),
    do: bytes |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  describe "GET /api/v1/headers/:height" do
    test "gives the 80 bytes, byte for byte, with what they hash to", %{conn: conn} do
      RealHeaders.insert(973_110)
      real = headers_vector()["real"]

      %{"data" => data, "meta" => meta} =
        conn |> get(~p"/api/v1/headers/973110") |> json_response(200)

      assert data["header"] == real["header"]
      assert data["hash"] == real["hash"]
      assert data["merkleroot"] == real["merkleRoot"]
      assert data["height"] == 973_110
      assert data["verified"] == true
      assert data["canonical"] == true
      assert meta["tip_height"] == 973_110
      assert meta["covers"] =~ "this index holds"

      bytes = Base.decode16!(data["header"], case: :lower)
      assert byte_size(bytes) == 80
      assert bytes |> sha256d() |> reverse() |> Base.encode16(case: :lower) == data["hash"]
    end

    test "genesis, which has no parent", %{conn: conn} do
      RealHeaders.insert(0)

      data = conn |> get(~p"/api/v1/headers/0") |> json_response(200) |> Map.fetch!("data")

      assert data["verified"] == true
      assert String.starts_with?(data["header"], "01000000" <> String.duplicate("00", 32))
    end

    test "a height we hold nothing at is a 404", %{conn: conn} do
      assert conn |> get(~p"/api/v1/headers/5") |> json_response(404)
    end

    test "anything but a height is a 400", %{conn: conn} do
      assert conn |> get("/api/v1/headers/abc") |> json_response(400)
      assert build_conn() |> get("/api/v1/headers/-1") |> json_response(400)
      assert build_conn() |> get("/api/v1/headers/1e5") |> json_response(400)
    end

    test "a height past the column is a 400, not a crash", %{conn: conn} do
      assert conn |> get("/api/v1/headers/2147483648") |> json_response(400)
      assert build_conn() |> get("/api/v1/headers/99999999999") |> json_response(400)
    end

    test "a row that fails its proof of work carries no header", %{conn: conn} do
      block_fixture(%{height: 7})

      data = conn |> get(~p"/api/v1/headers/7") |> json_response(200) |> Map.fetch!("data")

      assert data["verified"] == false
      assert data["header"] == nil
    end

    test "a real header with the nonce changed, under the hash it then has", %{conn: conn} do
      no_work = headers_vector()["noWork"]["header"] |> Base.decode16!(case: :lower)
      hash = no_work |> sha256d() |> reverse() |> Base.encode16(case: :lower)
      RealHeaders.insert(973_110, %{hash: hash, nonce: 3_907_804_538})

      data = conn |> get(~p"/api/v1/headers/973110") |> json_response(200) |> Map.fetch!("data")

      assert data["verified"] == false
      assert data["header"] == nil
    end

    test "a block the next stored block doesn't build on isn't canonical", %{conn: conn} do
      RealHeaders.insert(170)
      block_fixture(%{height: 171, prevblockhash: String.duplicate("f", 64)})

      data = conn |> get(~p"/api/v1/headers/170") |> json_response(200) |> Map.fetch!("data")

      assert data["canonical"] == false
      assert data["verified"] == true
    end

    test "a block the next stored block builds on is canonical", %{conn: conn} do
      header = RealHeaders.insert(170)
      block_fixture(%{height: 171, prevblockhash: header.hash})

      data = conn |> get(~p"/api/v1/headers/170") |> json_response(200) |> Map.fetch!("data")

      assert data["canonical"] == true
    end
  end

  describe "GET /api/v1/headers" do
    test "gives held headers in order, and names the gaps up to the tip", %{conn: conn} do
      RealHeaders.insert(9)
      RealHeaders.insert(170)

      %{"data" => data, "meta" => meta} =
        conn |> get(~p"/api/v1/headers?from=9&limit=3") |> json_response(200)

      assert [%{"height" => 9}] = data
      assert meta["missing"] == [10, 11]
      assert meta["count"] == 1
      assert meta["next_from"] == 12
      assert meta["tip_height"] == 170
    end

    test "the last header of a page sees the block above it", %{conn: conn} do
      RealHeaders.insert(170)
      block_fixture(%{height: 171, prevblockhash: String.duplicate("f", 64)})

      %{"data" => [header]} =
        conn |> get(~p"/api/v1/headers?from=170&limit=1") |> json_response(200)

      assert header["height"] == 170
      assert header["canonical"] == false
    end

    test "heights past the tip aren't missing", %{conn: conn} do
      RealHeaders.insert(9)

      meta =
        conn |> get(~p"/api/v1/headers?from=9&limit=5") |> json_response(200) |> Map.get("meta")

      assert meta["missing"] == []
      assert meta["next_from"] == nil
    end

    test "the cap is 2,000", %{conn: conn} do
      assert conn |> get(~p"/api/v1/headers?from=0&limit=2000") |> json_response(200)
      assert build_conn() |> get(~p"/api/v1/headers?from=0&limit=2001") |> json_response(400)
      assert build_conn() |> get(~p"/api/v1/headers?from=0&limit=0") |> json_response(400)
    end

    test "defaults to 100", %{conn: conn} do
      assert %{"meta" => %{"limit" => 100}} =
               conn |> get(~p"/api/v1/headers?from=0") |> json_response(200)
    end

    test "needs from", %{conn: conn} do
      assert conn |> get(~p"/api/v1/headers") |> json_response(400)
      assert build_conn() |> get(~p"/api/v1/headers?from=abc") |> json_response(400)
    end

    test "the top of the height column gives an answer", %{conn: conn} do
      assert %{"data" => []} =
               conn |> get(~p"/api/v1/headers?from=2147483647&limit=2000") |> json_response(200)
    end
  end

  describe "Chain.Headers" do
    test "reads the header's own columns, never the txid list" do
      RealHeaders.insert(170, %{tx: ["a txid"]})

      refute Map.has_key?(Headers.at(170), :tx)
      assert %{170 => %{height: 170}} = Headers.heights([170])
    end

    test "heights out of range are left out, not queried" do
      assert Headers.heights([-1, 4_000_000_000]) == %{}
      assert Headers.range(4_000_000_000, 10) == []
    end

    test "HeaderVerifier.serialize gives the bytes verify/2 hashes" do
      real = headers_vector()["real"]
      {:ok, bytes} = HeaderVerifier.serialize(real["explorerFields"])

      assert Base.encode16(bytes, case: :lower) == real["header"]
      assert HeaderVerifier.verify(real["explorerFields"], real["hash"]) == :ok
    end
  end
end
