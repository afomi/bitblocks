defmodule Bitblocks.DataPacksTest do
  use Bitblocks.DataCase, async: true

  alias Bitblocks.DataPacks.{Exporter, Importer, Spec}
  alias Bitblocks.{Chain, Repo}

  defmodule FakeRpc do
    def batch_getblockhash(heights) do
      {:ok, Map.new(heights, fn height -> {height, "hash-#{height}"} end)}
    end

    def getblock("hash-1", 1) do
      %{
        "hash" => "hash-1",
        "num_tx" => 2,
        "time" => 1_700_000_001,
        "bits" => "1d00ffff",
        "chainwork" => "abc",
        "difficulty" => 1,
        "height" => 1,
        "mediantime" => 1_700_000_001,
        "merkleroot" => "mr-1",
        "nextblockhash" => "hash-2",
        "previousblockhash" => "hash-0",
        "nonce" => 1,
        "size" => 512,
        "version" => 1,
        "tx" => ["tx-1", "tx-2"]
      }
    end

    def getblock("hash-2", 1) do
      %{
        "hash" => "hash-2",
        "num_tx" => 1,
        "time" => 1_700_000_002,
        "bits" => "1d00ffff",
        "chainwork" => "def",
        "difficulty" => 1,
        "height" => 2,
        "mediantime" => 1_700_000_002,
        "merkleroot" => "mr-2",
        "nextblockhash" => nil,
        "previousblockhash" => "hash-1",
        "nonce" => 2,
        "size" => 256,
        "version" => 1,
        "tx" => ["tx-3"]
      }
    end

    def batch_getrawtransaction(txids, 1) do
      {:ok,
       Map.new(txids, fn txid ->
         {txid,
          %{
            "txid" => txid,
            "hex" => "deadbeef-#{txid}",
            "version" => 1,
            "vin" => [%{"txid" => "prev-#{txid}", "value" => 1.25}],
            "vout" => [%{"n" => 0, "value" => 1.0}]
          }}
       end)}
    end
  end

  test "builds a valid spec with a stable default name" do
    assert {:ok, spec} =
             Spec.build(
               start_height: 0,
               end_height: 99_999,
               fidelity: "full",
               output_root: "/tmp/packs"
             )

    assert spec.name == "mainnet-000000-099999-full"
    assert spec.fidelity == :full
  end

  test "exports and imports a full pack" do
    tmp_root = Path.join(System.tmp_dir!(), "bitblocks-pack-#{System.unique_integer([:positive])}")

    assert {:ok, spec} =
             Spec.build(
               start_height: 1,
               end_height: 2,
               fidelity: "full",
               output_root: tmp_root,
               name: "test-pack"
             )

    assert {:ok, export_result} = Exporter.export_range(spec, rpc_module: FakeRpc)

    assert File.exists?(Path.join(export_result.output_dir, "manifest.json"))
    assert File.exists?(Path.join(export_result.output_dir, "blocks.jsonl"))
    assert File.exists?(Path.join(export_result.output_dir, "transactions.jsonl"))

    assert {:ok, import_result} = Importer.import_pack(export_result.output_dir, chunk_size: 2)

    assert import_result.blocks_imported == 2
    assert import_result.transactions_imported == 3

    assert Repo.aggregate(Chain.Block, :count, :id) == 2
    assert Repo.aggregate(Chain.Transaction, :count, :id) == 3

    block = Chain.get_block!(1)
    assert block.hash == "hash-1"
    assert block.sync_state == "completed"

    tx = Chain.get_transaction!("tx-1")
    assert tx.block_hash == "hash-1"
    assert tx.block_height == 1
    assert tx.output_count == 1
    assert tx.total_output_satoshis == 100_000_000
  end
end
