defmodule Bitblocks.TxTypes.CandidatesTest do
  # #51: unmatched shapes, ranked from raw bytes over a height range.
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.TxPipeline
  alias Bitblocks.Script
  alias Bitblocks.TxTypes.Candidates

  # OP_DUP OP_DROP <push>: a lock no type names.
  @shape_a %BSV.Script{chunks: [:OP_DUP, :OP_DROP, <<1, 2, 3>>]}
  @shape_b %BSV.Script{chunks: [:OP_2DUP, :OP_2DROP]}

  defp raw(scripts, salt) do
    outputs = Enum.map(scripts, &%BSV.TxOut{satoshis: 5, script: &1})

    input = %BSV.TxIn{
      outpoint: %BSV.OutPoint{hash: :binary.copy(<<salt>>, 32), vout: 0},
      script: %BSV.Script{chunks: []}
    }

    BSV.Tx.to_binary(%BSV.Tx{inputs: [input], outputs: outputs}, encoding: :hex)
  end

  defp custom_tx(txid, height, scripts, attrs \\ %{}) do
    %{
      txid: txid,
      block_height: height,
      raw: raw(scripts, height + 1),
      tx_types: ["custom"],
      tx_types_version: TxPipeline.version(:tx_types)
    }
    |> Map.merge(attrs)
    |> transaction_fixture()
  end

  test "ranks shapes by outputs, with first seen, growth, sample, protocols, examples" do
    custom_tx("a1", 10, [@shape_a], %{protocols: ["B://"]})
    custom_tx("a2", 80, [@shape_a, @shape_a], %{protocols: ["MAP"]})
    custom_tx("b1", 20, [@shape_b])

    result = Candidates.scan(0, 99)

    assert result.txs == 3
    assert result.unreadable == 0
    assert [a, b] = result.candidates

    assert a.template_hash == Script.template_hash(@shape_a)
    assert a.outputs == 3
    assert a.txs == 2
    assert a.first_height == 10
    assert a.first_txid == "a1"
    assert a.growth == 2.0
    assert a.protocols == ["B://", "MAP"]
    assert a.example_txids == ["a1", "a2"]
    assert a.per_10000_blocks == [%{from_height: 0, outputs: 3}]
    assert a.sample =~ "OP_DUP"

    assert b.outputs == 1
    assert b.growth == 0.0
  end

  test "a shape new in the later half has no growth figure" do
    custom_tx("late", 90, [@shape_a])

    assert %{candidates: [%{growth: nil}]} = Candidates.scan(0, 99)
  end

  test "only this range, this typing version, and custom txs count" do
    custom_tx("outside", 500, [@shape_a])
    custom_tx("old", 5, [@shape_a], %{tx_types_version: 0})
    custom_tx("typed", 6, [@shape_a], %{tx_types: ["p2pkh"]})

    assert %{txs: 0, candidates: []} = Candidates.scan(0, 99)
  end

  test "an older row stamp counts when its block is stamped typed at this version" do
    block = block_fixture(%{height: 5})
    custom_tx("old", 5, [@shape_a], %{tx_types_version: 0, block_hash: block.hash})
    assert %{txs: 0} = Candidates.scan(0, 99)

    Bitblocks.Repo.update_all(
      Ecto.Query.from(b in Bitblocks.Chain.Block, where: b.id == ^block.id),
      set: [tx_types_version: TxPipeline.version(:tx_types)]
    )

    assert %{txs: 1, candidates: [_]} = Candidates.scan(0, 99)
  end

  test "a tx with no readable bytes is counted, not hidden" do
    custom_tx("unreadable", 7, [@shape_a], %{raw: "zz"})

    assert %{txs: 1, unreadable: 1, candidates: []} = Candidates.scan(0, 99)
  end

  test "limit caps the list" do
    custom_tx("a", 1, [@shape_a])
    custom_tx("b", 2, [@shape_b])

    assert %{candidates: [_one]} = Candidates.scan(0, 99, limit: 1)
  end
end
