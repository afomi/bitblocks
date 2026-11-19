defmodule Bitblocks.DerivationsFillRawTest do
  # #123: a backfill page loads raw under a byte budget, never more than the
  # budget or one tx larger than it.
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.Derivations

  defp row(id, bytes), do: %{id: id, raw_bytes: bytes}

  describe "within_bytes/2" do
    test "the longest prefix within the budget" do
      rows = [row(1, 40), row(2, 40), row(3, 40)]
      assert [%{id: 1}, %{id: 2}] = Derivations.within_bytes(rows, 100)
    end

    test "always the first row, however large" do
      assert [%{id: 1}] = Derivations.within_bytes([row(1, 500), row(2, 1)], 100)
    end

    test "rows that need no raw cost nothing" do
      rows = [row(1, 90), row(2, nil), row(3, nil), row(4, 20)]
      assert [_, _, _] = Derivations.within_bytes(rows, 100)
    end
  end

  describe "fill_raw/2" do
    setup do
      block = block_fixture(%{height: 30, sync_state: "completed"})

      txs =
        for n <- 1..3 do
          transaction_fixture(%{
            block_hash: block.hash,
            block_height: block.height,
            raw: String.duplicate("ab", 50 * n)
          })
        end

      %{txs: txs}
    end

    defp sized(txs, needed) do
      for t <- txs, do: %{id: t.id, raw_bytes: if(t.id in needed, do: byte_size(t.raw))}
    end

    test "loads raw only for the rows that need it, under the budget", %{txs: [a, b, c]} do
      rows = sized([a, b, c], [a.id, c.id])

      assert [%{id: ia, raw: ra}, %{id: ib, raw: nil}, %{id: ic, raw: rc}] =
               Derivations.fill_raw(rows, page_raw_bytes: 1_000)

      assert {ia, ib, ic} == {a.id, b.id, c.id}
      assert {ra, rc} == {a.raw, c.raw}
    end

    test "stops at the budget; the caller carries on after the last row", %{txs: [a, b, c]} do
      rows = sized([a, b, c], [a.id, b.id, c.id])
      # a is 100 bytes, b 200: the budget fits a alone.
      assert [%{id: id}] = Derivations.fill_raw(rows, page_raw_bytes: 150)
      assert id == a.id
    end

    test "an empty page is empty" do
      assert [] == Derivations.fill_raw([])
    end
  end
end
