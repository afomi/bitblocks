defmodule Bitblocks.BitcomTest do
  @moduledoc """
  The Bitcom command log: every `$` command is authored by the address that
  funded the tx, and a namespace's files and routes are views over the log.
  Spec: https://github.com/unwriter/Bitcom (`bin/`, `0.1.0.md`).
  """
  use Bitblocks.DataCase, async: true

  import Bitblocks.BitcomFixtures

  alias Bitblocks.{Bitcom, ProtocolRegistry, Release}
  alias Bitblocks.Bitcom.Command
  alias Bitblocks.Chain.Transaction

  @b "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"

  defp raw_tx(privkey, outputs, salt \\ 9), do: bitcom_raw_tx(privkey, outputs, salt)
  defp store(raw, attrs \\ %{}), do: store_analyzed_tx(raw, attrs)

  defp index(raw, attrs \\ %{}) do
    tx = store(raw, attrs)
    {:ok, result} = Bitcom.index(tx)
    {tx, result}
  end

  defp logged(txid),
    do: Repo.all(from c in Command, where: c.txid == ^txid, order_by: c.output_index)

  setup do
    admin = BSV.PrivKey.new()
    %{admin: admin, admin_addr: address(admin)}
  end

  describe "useradd" do
    test "is valid and proves ownership when funded by the claimed address", ctx do
      {tx, result} = index(raw_tx(ctx.admin, [["$", "useradd", ctx.admin_addr]]))

      assert result == %{commands: 1, proofs: 1}
      assert [%Command{valid: true, namespace: ns, actor: actor}] = logged(tx.txid)
      assert ns == ctx.admin_addr and actor == ctx.admin_addr

      assert ProtocolRegistry.get_protocol_by_address(ctx.admin_addr).ownership_proof_txid ==
               tx.txid
    end

    test "claiming another address is logged invalid and proves nothing", ctx do
      victim = address(BSV.PrivKey.new())
      {tx, result} = index(raw_tx(ctx.admin, [["$", "useradd", victim]]))

      assert result == %{commands: 1, proofs: 0}
      assert [%Command{valid: false, namespace: ^victim, reason: reason}] = logged(tx.txid)
      assert reason =~ "not funded by"
    end
  end

  describe "echo … to" do
    test "writes a file in the actor's namespace; the latest write wins", ctx do
      index(raw_tx(ctx.admin, [["$", "echo", "v1", "to", "readme"]], 1), %{block_height: 100})

      {tx2, _} =
        index(raw_tx(ctx.admin, [["$", "echo", "v2", "to", "readme"]], 2), %{block_height: 200})

      assert [%{file: "readme", command: latest, history: history}] = Bitcom.files(ctx.admin_addr)
      assert latest.content == "v2" and latest.txid == tx2.txid
      assert Enum.map(history, & &1.content) == ["v2", "v1"]
    end

    test "an unconfirmed write is newer than any confirmed one", ctx do
      index(raw_tx(ctx.admin, [["$", "echo", "mempool", "to", "readme"]], 1))
      index(raw_tx(ctx.admin, [["$", "echo", "mined", "to", "readme"]], 2), %{block_height: 500})

      assert [%{command: %{content: "mempool"}}] = Bitcom.files(ctx.admin_addr)
    end

    test "without `to <file>` is logged as malformed", ctx do
      {tx, _} = index(raw_tx(ctx.admin, [["$", "echo", "orphan"]]))

      assert [%Command{valid: false, reason: "malformed echo"}] = logged(tx.txid)
      assert Bitcom.files(ctx.admin_addr) == []
    end

    test "keeps non-UTF-8 bytes as 0x-hex", ctx do
      {tx, _} = index(raw_tx(ctx.admin, [["$", "echo", <<0xFF, 0x00>>, "to", "blob"]]))

      assert [%Command{valid: true, content: "0xff00"}] = logged(tx.txid)
    end
  end

  describe "cat … to" do
    test "points a file at bit:// content", ctx do
      locator = "bit://#{@b}/" <> String.duplicate("e", 64)
      index(raw_tx(ctx.admin, [["$", "cat", locator, "to", "readme"]]))

      assert [%{file: "readme", command: %{command: "cat", locator: ^locator}}] =
               Bitcom.files(ctx.admin_addr)
    end

    test "rejects a non-bit:// source", ctx do
      {tx, _} = index(raw_tx(ctx.admin, [["$", "cat", "https://x", "to", "readme"]]))
      assert [%Command{valid: false, reason: "malformed cat"}] = logged(tx.txid)
    end
  end

  describe "route" do
    test "the admin enables, a provider adds; endpoints attach to the enabled route", ctx do
      provider = BSV.PrivKey.new()
      endpoint = "https://media.example/${tx}"

      index(raw_tx(ctx.admin, [["$", "route", "enable", "/:tx"]], 1), %{block_height: 1})

      {added, _} =
        index(raw_tx(provider, [["$", "route", "add", ctx.admin_addr, "/:tx", endpoint]], 2), %{
          block_height: 2
        })

      assert [%{matcher: "/:tx", endpoints: [ep]}] = Bitcom.routes(ctx.admin_addr)
      assert ep == %{provider: address(provider), endpoint: endpoint, txid: added.txid}
    end

    test "the admin may not add an endpoint to its own route", ctx do
      {tx, _} =
        index(
          raw_tx(ctx.admin, [["$", "route", "add", ctx.admin_addr, "/:tx", "https://x/${tx}"]])
        )

      assert [%Command{valid: false, reason: reason}] = logged(tx.txid)
      assert reason =~ "admin enables routes"
    end

    test "endpoints for a route that was never enabled are not served", ctx do
      provider = BSV.PrivKey.new()
      index(raw_tx(provider, [["$", "route", "add", ctx.admin_addr, "/:tx", "https://x/${tx}"]]))

      assert Bitcom.routes(ctx.admin_addr) == []
    end
  end

  describe "parsing" do
    test "finds a `$` segment after a pipe and stops at the next pipe", ctx do
      {tx, _} =
        index(raw_tx(ctx.admin, [[@b, "data", "|", "$", "echo", "hi", "to", "f", "|", "tail"]]))

      assert [%Command{valid: true, args: ["hi", "to", "f"]}] = logged(tx.txid)
    end

    test "logs one command per OP_RETURN output", ctx do
      {tx, result} =
        index(
          raw_tx(ctx.admin, [
            ["$", "echo", "a", "to", "one"],
            ["$", "echo", "b", "to", "two"]
          ])
        )

      assert result.commands == 2
      assert Enum.map(logged(tx.txid), & &1.output_index) == [0, 1]
    end

    test "logs unknown commands as invalid", ctx do
      {tx, _} = index(raw_tx(ctx.admin, [["$", "rm", "-rf"]]))

      assert [%Command{valid: false, command: "rm", reason: "unknown command \"rm\""}] =
               logged(tx.txid)
    end

    test "is idempotent", ctx do
      tx = store(raw_tx(ctx.admin, [["$", "echo", "a", "to", "one"]]))

      assert {:ok, %{commands: 1}} = Bitcom.index(tx)
      assert {:ok, %{commands: 0}} = Bitcom.index(tx)
      assert length(logged(tx.txid)) == 1
    end

    test "is a no-op for a tx not tagged Bitcom", ctx do
      tx = store(raw_tx(ctx.admin, [["hello"]]))
      assert Bitcom.index(tx) == {:ok, %{commands: 0, proofs: 0}}
    end
  end

  describe "directory" do
    test "tiers: proven, then self-described, then listed", ctx do
      writer = BSV.PrivKey.new()
      {:ok, _} = ProtocolRegistry.create_protocol(%{address: @b, name: "B://"})

      index(raw_tx(ctx.admin, [["$", "useradd", ctx.admin_addr]], 1))
      index(raw_tx(writer, [["$", "echo", "hello", "to", "readme"]], 2))

      tiers = Map.new(Bitcom.directory(), &{&1.address, &1.tier})

      assert tiers[ctx.admin_addr] == :proven
      assert tiers[address(writer)] == :self_described
      assert tiers[@b] == :listed

      order = Enum.map(Bitcom.directory(), & &1.tier) |> Enum.dedup()
      assert order == Enum.filter([:proven, :self_described, :listed], &(&1 in order))
    end

    test "names a handler-only prefix by its protocol tag and counts tagged txs" do
      entry = Bitcom.entry(@b)
      assert entry.tag == "B://"
      assert entry.name == "B://"
      assert entry.usage == 0
    end

    test "export carries the txids needed to re-verify an entry", ctx do
      {proof, _} = index(raw_tx(ctx.admin, [["$", "useradd", ctx.admin_addr]], 1))
      {file, _} = index(raw_tx(ctx.admin, [["$", "echo", "hi", "to", "readme"]], 2))

      assert %{proof_txid: proof_txid, tier: "proven", files: [%{txid: file_txid}]} =
               Bitcom.export_namespace(ctx.admin_addr)

      assert proof_txid == proof.txid and file_txid == file.txid
    end

    test "address?/1 accepts base58check P2PKH only" do
      assert Bitcom.address?(@b)
      refute Bitcom.address?("19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAuu")
      refute Bitcom.address?("$")
    end
  end

  describe "compose/2" do
    test "a composed command indexes as valid when funded by the funder", ctx do
      {:ok, out} = Bitcom.compose(["echo", "hello", "to", "readme"], ctx.admin_addr)
      assert out.namespace == ctx.admin_addr

      {:ok, script} = BSV.Script.from_binary(out.script_hex, encoding: :hex)
      [_, _ | cells] = script.chunks
      {tx, _} = index(raw_tx(ctx.admin, [cells]))

      assert [%Command{valid: true, file: "readme", content: "hello"}] = logged(tx.txid)
    end

    test "rejects what the indexer would reject", ctx do
      assert {:error, "the admin enables routes; a provider adds them"} =
               Bitcom.compose(
                 ["route", "add", ctx.admin_addr, "/:tx", "https://x"],
                 ctx.admin_addr
               )

      assert {:error, "malformed echo"} = Bitcom.compose(["echo", "x"], ctx.admin_addr)
      assert {:error, "funder is not a valid address"} = Bitcom.compose(["useradd", "x"], "x")
    end
  end

  describe "Release.analyze_transactions/1" do
    test "indexes Bitcom commands for re-analyzed transactions", ctx do
      tx = store(raw_tx(ctx.admin, [["$", "useradd", ctx.admin_addr]]))

      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
        set: [script_analysis_version: nil]
      )

      assert :ok = Release.analyze_transactions()
      assert [%Command{valid: true}] = logged(tx.txid)

      assert ProtocolRegistry.get_protocol_by_address(ctx.admin_addr).ownership_proof_txid ==
               tx.txid
    end

    # Before keyset pagination, a tx that failed to analyze kept its old
    # version and was re-selected by every batch: with batch_size 1 the
    # backfill looped forever on it.
    @tag timeout: 10_000
    test "moves past transactions that fail to analyze", ctx do
      Repo.insert!(%Transaction{txid: String.duplicate("e", 64), raw: "zz"})
      tx = store(raw_tx(ctx.admin, [["$", "useradd", ctx.admin_addr]]))

      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
        set: [script_analysis_version: nil]
      )

      assert :ok = Release.analyze_transactions(batch_size: 1)
      assert [%Command{valid: true}] = logged(tx.txid)
    end
  end
end
