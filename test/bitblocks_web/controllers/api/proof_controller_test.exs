defmodule BitblocksWeb.Api.ProofControllerTest do
  # RpcStub is one shared table, so not async.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures
  import Ecto.Query

  alias Bitblocks.Chain.{Block, MerkleProof}
  alias Bitblocks.{FirstSpendFixtures, Repo}
  alias BitblocksWeb.RpcStub

  # Block 170's real header: the first spend (Satoshi to Hal Finney) is its tx 1.
  @hash_170 "00000000d1145790a8694403d4063f323d499e655c83426834d4ce2f8dd4a2ee"
  @prev_170 "000000002a22cfee1f2c846adbd12b3e183d4f97683f85dad08a79780a84bd55"
  @root_170 "7dac2c5666815c17a3b36427de37bb9d2e2c5ccec3f8633eb91a4205cb4c10ff"

  setup do
    RpcStub.setup()
    :ok
  end

  # The fixture's block 170 carries a placeholder hash and root; give it the real ones.
  defp real_block_170(attrs \\ %{}) do
    FirstSpendFixtures.insert_first_spend()
    fixture_hash = String.pad_leading("170", 64, "b")

    Repo.update_all(
      from(t in "transactions", where: t.block_hash == ^fixture_hash),
      set: [block_hash: @hash_170]
    )

    Repo.get_by!(Block, height: 170)
    |> Ecto.Changeset.change(
      Map.merge(
        %{hash: @hash_170, merkleroot: @root_170, prevblockhash: @prev_170, nextblockhash: nil},
        attrs
      )
    )
    |> Repo.update!()
  end

  defp proof(conn, txid), do: get(conn, ~p"/api/v1/txs/#{txid}/proof")

  # sha256d over internal byte order, displayed big-endian: a second,
  # independent root computation for the assertions.
  defp hash_pair(a, b) do
    digest = :crypto.hash(:sha256, :crypto.hash(:sha256, internal(a) <> internal(b)))
    digest |> rev() |> Base.encode16(case: :lower)
  end

  defp internal(hex), do: hex |> Base.decode16!(case: :mixed) |> rev()
  defp rev(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  defp climb(txid, index, siblings) do
    {root, _} =
      Enum.reduce(siblings, {txid, index}, fn sib, {acc, i} ->
        if rem(i, 2) == 0,
          do: {hash_pair(acc, sib), div(i, 2)},
          else: {hash_pair(sib, acc), div(i, 2)}
      end)

    root
  end

  describe "a proof the caller can check" do
    test "a BEEF over the served cap is a 413 naming /raw and /proof (#68)", %{conn: conn} do
      real_block_170()
      Application.put_env(:bitblocks, :beef_serve_max_bytes, 1_000)
      on_exit(fn -> Application.delete_env(:bitblocks, :beef_serve_max_bytes) end)

      txid = FirstSpendFixtures.first_spend()

      body =
        conn
        |> get(~p"/api/v1/txs/#{String.upcase(txid)}/beef")
        |> json_response(413)

      assert body["reason"] == "too_large"
      assert body["max_bytes"] == 1_000
      assert body["raw_url"] == "/api/v1/txs/#{txid}/raw"
      assert body["proof_url"] == "/api/v1/txs/#{txid}/proof"
    end

    test "an uppercase txid gets the same proof, as /beef does (#68)", %{conn: conn} do
      real_block_170()

      data =
        conn
        |> proof(String.upcase(FirstSpendFixtures.first_spend()))
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["txid"] == FirstSpendFixtures.first_spend()
      assert data["merkleroot"] == @root_170
    end

    test "the first spend in block 170 (2 txs) climbs to the header's real root", %{conn: conn} do
      real_block_170()
      # Two blocks above it are stored, so it has 3 confirmations.
      block_fixture(%{height: 171, prevblockhash: @hash_170})
      block_fixture(%{height: 172})

      data =
        conn
        |> proof(FirstSpendFixtures.first_spend())
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["txid"] == FirstSpendFixtures.first_spend()
      assert data["index"] == 1
      assert data["siblings"] == [FirstSpendFixtures.coinbase_170()]
      assert data["merkleroot"] == @root_170
      assert data["block_hash"] == @hash_170
      assert data["block_height"] == 170
      assert data["confirmations"] == 3
      assert data["source"] == "block_txids"
      assert data["trust"]["header"] =~ "proof-of-work"

      # The caller's own check, with nothing from bitblocks but the JSON.
      assert climb(data["txid"], data["index"], data["siblings"]) == data["merkleroot"]
    end

    test "the coinbase at index 0 gets its sibling on the right", %{conn: conn} do
      real_block_170()

      data =
        conn
        |> proof(FirstSpendFixtures.coinbase_170())
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["index"] == 0
      assert data["siblings"] == [FirstSpendFixtures.first_spend()]
      assert data["confirmations"] == 1
      assert climb(data["txid"], 0, data["siblings"]) == @root_170
    end

    test "in a block with an odd number of txs the last hash is paired with itself", %{conn: conn} do
      [a, b, c] =
        txids = for n <- 1..3, do: n |> Integer.to_string() |> String.pad_leading(64, "a")

      root = hash_pair(hash_pair(a, b), hash_pair(c, c))

      block = block_fixture(%{tx: txids, num_tx: 3, merkleroot: root, nextblockhash: nil})
      transaction_fixture(%{txid: c, block_hash: block.hash, block_height: block.height})

      data = conn |> proof(c) |> json_response(200) |> Map.fetch!("data")

      assert data["index"] == 2
      assert data["siblings"] == [c, hash_pair(a, b)]
      assert climb(c, 2, data["siblings"]) == root
    end
  end

  describe "never an unchecked proof" do
    test "a txid list that doesn't rebuild the header's root is not a 200", %{conn: conn} do
      real_block_170(%{merkleroot: String.duplicate("cd", 32)})

      conn = proof(conn, FirstSpendFixtures.first_spend())
      assert conn.status == 500
      assert json_response(conn, 500)["error"] =~ "merkle root"
    end

    test "a tx whose block was orphaned (row deleted by the reorg) is a 409", %{conn: conn} do
      orphan_hash = String.duplicate("0e", 32)

      transaction_fixture(%{
        txid: String.duplicate("ab", 32),
        block_hash: orphan_hash,
        block_height: 5
      })

      conn = proof(conn, String.duplicate("ab", 32))
      assert json_response(conn, 409)["error"] =~ "canonical"
    end

    test "a block the stored child doesn't build on is a 409", %{conn: conn} do
      real_block_170()
      block_fixture(%{height: 171, prevblockhash: String.duplicate("99", 32)})

      conn = proof(conn, FirstSpendFixtures.first_spend())
      assert json_response(conn, 409)["error"] =~ "canonical"
    end

    test "a tx row whose height disagrees with its block is a 409", %{conn: conn} do
      block = block_fixture(%{tx: ["x"], num_tx: 1, merkleroot: String.duplicate("cd", 32)})
      tx = transaction_fixture(%{block_hash: block.hash, block_height: block.height + 1})

      assert conn |> proof(tx.txid) |> json_response(409)
    end

    # Older prod rows were stored before block_height was written (see
    # Release.backfill_tx_block_heights/0); the block_hash still names the block.
    test "a tx row with no block_height still gets its proof from its block", %{conn: conn} do
      real_block_170()
      block_fixture(%{height: 171, prevblockhash: @hash_170})

      Repo.update_all(
        from(t in Bitblocks.Chain.Transaction,
          where: t.txid == ^FirstSpendFixtures.first_spend()
        ),
        set: [block_height: nil]
      )

      data =
        conn
        |> proof(FirstSpendFixtures.first_spend())
        |> json_response(200)
        |> Map.fetch!("data")

      assert {data["block_height"], data["index"]} == {170, 1}
    end

    test "a tx we don't store is a 404, not a proof", %{conn: conn} do
      assert conn |> proof(String.duplicate("ab", 32)) |> json_response(404)
    end
  end

  describe "a block whose txid list isn't stored: the node's gettxoutproof, parsed and checked" do
    setup do
      block = real_block_170(%{tx: []})
      %{block: block}
    end

    test "a valid partial merkle tree gives the same proof", %{conn: conn} do
      RpcStub.stub_gettxoutproof(
        [FirstSpendFixtures.first_spend()],
        @hash_170,
        merkleblock_170(@root_170)
      )

      data =
        conn
        |> proof(FirstSpendFixtures.first_spend())
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["index"] == 1
      assert data["siblings"] == [FirstSpendFixtures.coinbase_170()]
      assert data["source"] == "gettxoutproof"
      assert climb(data["txid"], 1, data["siblings"]) == @root_170
    end

    test "a node blob for some other header is not a 200", %{conn: conn} do
      # The header no longer hashes to block 170's hash.
      RpcStub.stub_gettxoutproof(
        [FirstSpendFixtures.first_spend()],
        @hash_170,
        merkleblock_170(String.duplicate("cd", 32))
      )

      conn = proof(conn, FirstSpendFixtures.first_spend())
      assert conn.status == 500
    end

    test "the real header with a tampered tree is not a 200", %{conn: conn} do
      RpcStub.stub_gettxoutproof(
        [FirstSpendFixtures.first_spend()],
        @hash_170,
        merkleblock_170(@root_170, [String.duplicate("00", 32), FirstSpendFixtures.first_spend()])
      )

      assert conn |> proof(FirstSpendFixtures.first_spend()) |> json_response(500)
    end

    test "the block 170 header in these tests is real: its hash meets its proof-of-work target" do
      header = %{
        "version" => 1,
        "previousblockhash" => @prev_170,
        "merkleroot" => @root_170,
        "time" => 1_231_731_025,
        "bits" => "1d00ffff",
        "nonce" => 1_889_418_792
      }

      assert Bitblocks.Chain.HeaderVerifier.verify(header, @hash_170) == :ok
    end

    test "a node that can't give the proof is a 503", %{conn: conn} do
      assert conn |> proof(FirstSpendFixtures.first_spend()) |> json_response(503)
    end
  end

  test "the example in docs/MERKLE_PROOFS.md has the fields and values the endpoint returns",
       %{conn: conn} do
    [_, after_heading] =
      "docs/MERKLE_PROOFS.md" |> File.read!() |> String.split("### Example: the first spend")

    [_, json_and_rest] = String.split(after_heading, "```json\n", parts: 2)
    [json, _] = String.split(json_and_rest, "\n```", parts: 2)
    documented = json |> Jason.decode!() |> Map.fetch!("data")

    real_block_170()

    data =
      conn
      |> proof(FirstSpendFixtures.first_spend())
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.sort(Map.keys(documented)) == Enum.sort(Map.keys(data))
    assert Enum.sort(Map.keys(documented["trust"])) == Enum.sort(Map.keys(data["trust"]))

    for key <- ~w(txid index siblings merkleroot block_hash block_height confirmations source) do
      assert documented[key] == data[key], key
    end

    assert documented["trust"]["header"] == data["trust"]["header"]
  end

  test "MerkleProof.build/1 is the same answer the endpoint gives" do
    real_block_170()

    assert {:ok, %{index: 1, source: "block_txids"}} =
             MerkleProof.build(FirstSpendFixtures.first_spend())
  end

  # A serialized merkleblock (what `gettxoutproof` returns) for block 170,
  # matching tx 1: header, tx count 2, hashes [coinbase, first spend], flags 101.
  # `leaves` replaces the two hashes, to tamper with the tree.
  defp merkleblock_170(
         header_root,
         leaves \\ [FirstSpendFixtures.coinbase_170(), FirstSpendFixtures.first_spend()]
       ) do
    le = &internal/1

    header =
      <<1::little-32>> <>
        le.(@prev_170) <>
        le.(header_root) <>
        <<1_231_731_025::little-32, 0x1D00FFFF::little-32, 1_889_418_792::little-32>>

    (header <>
       <<2::little-32, 2>> <>
       Enum.map_join(leaves, &le.(&1)) <> <<1, 0b101>>)
    |> Base.encode16(case: :lower)
  end

  describe "GET /api/v1/txs/:txid/beef" do
    test "serves BEEF as hex, the tx last", %{conn: conn} do
      real_block_170()

      data =
        conn
        |> get(~p"/api/v1/txs/#{FirstSpendFixtures.first_spend()}/beef")
        |> json_response(200)
        |> Map.fetch!("data")

      assert String.starts_with?(data["beef"], "0100beef")
      assert List.last(data["transactions"]) == FirstSpendFixtures.first_spend()
      assert data["block_height"] == 170
      assert is_boolean(data["complete"])
    end

    test "answers as the proof does for a tx we don't hold", %{conn: conn} do
      assert conn |> get(~p"/api/v1/txs/#{String.duplicate("ab", 32)}/beef") |> json_response(404)
    end

    test "?format=atomic serves Atomic BEEF: the tx and its BUMP alone", %{conn: conn} do
      real_block_170()
      txid = FirstSpendFixtures.first_spend()

      data =
        conn
        |> get(~p"/api/v1/txs/#{txid}/beef?format=atomic")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["format"] == "atomic"
      assert data["transactions"] == [txid]
      assert data["complete"]
      assert String.starts_with?(data["beef"], "01010101")
      assert binary_part(data["beef"], 8, 64) == rev_hex(txid)
    end

    test "another format is a 400", %{conn: conn} do
      txid = FirstSpendFixtures.first_spend()

      assert conn |> get(~p"/api/v1/txs/#{txid}/beef?format=v9") |> json_response(400)
    end
  end

  defp rev_hex(txid), do: txid |> internal() |> Base.encode16(case: :lower)
end
