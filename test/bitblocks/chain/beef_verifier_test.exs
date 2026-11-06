defmodule Bitblocks.Chain.BeefVerifierTest do
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.{Beef, BeefVerifier, Block, Headers}
  alias Bitblocks.Chain.Beef.Reader
  alias Bitblocks.{FirstSpendFixtures, RealHeaders, Repo}
  alias BitblocksWeb.RpcStub

  @fixtures Path.expand("../../support/fixtures/brc", __DIR__)
  @brc62_root "bb6f640cc4ee56bf38eb5a1969ac0c16caa2d3d202b22bf3735d10eec0ca6e00"
  @v1 <<0x01, 0x00, 0xBE, 0xEF>>

  defp hex_vector(name) do
    @fixtures |> Path.join(name) |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
  end

  defp json_vector(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp brc62, do: hex_vector("brc62_beef.hex")

  defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))

  defp reverse(bytes),
    do: bytes |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  defp internal(txid), do: txid |> Base.decode16!(case: :lower) |> reverse()
  defp display(hash), do: hash |> reverse() |> Base.encode16(case: :lower)

  defp tx(prev, tag \\ 0) do
    <<1::little-32, 1, prev::binary, tag::little-32, 0, 0xFFFFFFFF::little-32, 1, 1000::little-64,
      1, 0x51, 0::little-32>>
  end

  defp prev(tag \\ 1), do: :crypto.hash(:sha256, <<tag>>)

  defp leaf(offset, hash, txid? \\ false),
    do: %{offset: offset, hash: hash, txid: txid?, duplicate: false}

  defp status_of(answer, txid), do: Enum.find(answer.transactions, &(&1.txid == txid))

  # A header as `Chain.Headers` gives it, for `evaluate/3`.
  defp header(root, attrs \\ %{}) do
    Map.merge(
      %{hash: "a block", merkleroot: root, num_tx: nil, verified: true, canonical: true},
      attrs
    )
  end

  defp evaluate(bytes, headers, tip \\ 1_000) do
    {:ok, beef} = Reader.parse(bytes)
    BeefVerifier.evaluate(beef, headers, tip)
  end

  test "the headers these tests rely on are real: each passes its proof of work" do
    for height <- RealHeaders.heights() do
      RealHeaders.insert(height)
      assert %{verified: true} = Headers.at(height)
    end
  end

  describe "the BRC-62 example against block 814435's real header" do
    setup do
      RealHeaders.insert(814_435)
      {:ok, answer} = BeefVerifier.verify(brc62())
      {:ok, beef} = Reader.parse(brc62())
      [parent, payment] = beef.transactions
      %{answer: answer, parent: parent, payment: payment}
    end

    test "the parent is proven at its height and root", %{answer: answer, parent: parent} do
      assert %{
               status: :proven,
               block_height: 814_435,
               merkleroot: @brc62_root,
               block_hash: "000000000000000003f49bf7c058cc10c205b0fe381c218288bf92fd974c672b",
               confirmations: 1,
               reason: nil
             } = status_of(answer, parent.txid)

      assert answer.proven == [parent.txid]
    end

    test "the payment has no BUMP: anchored, and not in a block", %{answer: a, payment: payment} do
      assert a.subject_txid == payment.txid
      assert a.status == :anchored
      assert a.in_block == false
      assert a.block_height == nil
    end

    test "the claim is inclusion, and says what it doesn't check", %{answer: answer} do
      assert answer.claim =~ "Inclusion in a block only"
      assert "scripts" in answer.not_checked
      assert "token_validity" in answer.not_checked
    end
  end

  describe "shared vectors" do
    test "a real mainnet tx against block 973110's real header" do
      RealHeaders.insert(973_110)
      vector = json_vector("woc_mainnet_v1.json")
      raw = Base.decode16!(vector["rawTx"], case: :lower)
      bump = Base.decode16!(vector["bump"], case: :lower)

      {:ok, answer} =
        BeefVerifier.verify(<<@v1::binary, 1, bump::binary, 1, raw::binary, 1, 0>>)

      assert answer.status == :proven
      assert answer.subject_txid == vector["txid"]
      assert answer.block_height == 973_110
      assert answer.merkleroot == vector["merkleRoot"]
    end

    test "the two-input BEEF: its mined input proven, the subject anchored" do
      vector = json_vector("vault_beef_v1.json")
      [mined, unconfirmed] = vector["facts"]["inputs"]
      height = mined["anchor"]["blockHeight"]

      answer =
        evaluate(Base.decode16!(vector["unsignedBeef"], case: :lower), %{
          height => header(mined["anchor"]["merkleRoot"])
        })

      assert status_of(answer, mined["txid"]).status == :proven
      assert status_of(answer, unconfirmed["txid"]).status == :anchored
      assert answer.subject_txid == vector["unsignedTxid"]
      assert answer.status == :anchored
    end

    test "Atomic BEEF from the SDK reports its format and subject" do
      RealHeaders.insert(814_435)
      vector = json_vector("beef_sdk_v1.json")

      {:ok, answer} = BeefVerifier.verify(Base.decode16!(vector["brc62_atomic"], case: :lower))

      assert answer.format == "atomic_beef_v1"
      assert answer.subject_txid == vector["brc62_subject"]
      assert answer.status == :anchored
    end

    test "a BEEF V2 txid-only entry is never proven, and neither is what rests on it" do
      RealHeaders.insert(814_435)
      vector = json_vector("beef_sdk_v1.json")

      {:ok, answer} =
        BeefVerifier.verify(Base.decode16!(vector["brc62_v2_txid_only"], case: :lower))

      assert answer.format == "beef_v2"
      assert %{status: :unknown, reason: :txid_only} = status_of(answer, vector["brc62_parent"])
      assert answer.status == :unknown
      assert answer.reason == :ancestor_unknown
      assert answer.proven == []
    end
  end

  describe "what isn't known stays unknown" do
    test "a height we hold no header for" do
      {:ok, answer} = BeefVerifier.verify(brc62())

      assert answer.status == :unknown
      assert answer.reason == :ancestor_unknown
      assert answer.proven == []

      [parent | _] = answer.transactions
      assert %{status: :unknown, reason: :height_unknown} = parent
      assert parent.block_height == 814_435
      assert parent.merkleroot == @brc62_root
    end

    test "a height past the height column gives an answer, not a crash" do
      raw = tx(prev())
      hash = sha256d(raw)
      bump = Beef.encode_bump(%{height: 4_000_000_000, path: [[leaf(0, hash, true)]]})

      {:ok, answer} = BeefVerifier.verify(<<@v1::binary, 1, bump::binary, 1, raw::binary, 1, 0>>)

      assert answer.status == :unknown
      assert answer.reason == :height_unknown
    end

    test "a row that can't show its proof of work counts for nothing" do
      block_fixture(%{height: 814_435, merkleroot: @brc62_root})

      {:ok, answer} = BeefVerifier.verify(brc62())

      assert [%{status: :unknown, reason: :header_unverified} | _] = answer.transactions
      assert answer.proven == []
    end

    test "a block the next stored block doesn't build on counts for nothing" do
      RealHeaders.insert(814_435)
      block_fixture(%{height: 814_436, prevblockhash: String.duplicate("f", 64)})

      {:ok, answer} = BeefVerifier.verify(brc62())

      assert [%{status: :unknown, reason: :not_canonical} | _] = answer.transactions
      assert answer.proven == []
    end

    test "a block the next stored block does build on is proven" do
      header = RealHeaders.insert(814_435)
      block_fixture(%{height: 814_436, prevblockhash: header.hash})

      {:ok, answer} = BeefVerifier.verify(brc62())

      assert [%{status: :proven, confirmations: 2} | _] = answer.transactions
    end

    test "a tx with no BUMP and a parent outside the BEEF" do
      raw = tx(prev())
      answer = evaluate(<<@v1::binary, 0, 1, raw::binary, 0>>, %{})

      assert answer.status == :unknown
      assert answer.reason == :no_inputs_in_beef
    end
  end

  describe "evidence that doesn't hold" do
    test "a root that isn't the header's" do
      RealHeaders.insert(813_706)
      {:ok, beef} = Reader.parse(brc62())
      [bump] = beef.bumps
      [parent, payment] = beef.transactions

      elsewhere =
        Beef.encode([%{bump | height: 813_706}], [
          {parent.raw, parent.bump_index},
          {payment.raw, nil}
        ])

      {:ok, answer} = BeefVerifier.verify(elsewhere)

      assert [%{status: :failed, reason: :root_mismatch} = shown, payment_shown] =
               answer.transactions

      assert shown.merkleroot == @brc62_root
      assert %{status: :failed, reason: :ancestor_failed} = payment_shown
      assert answer.status == :failed
      assert answer.proven == []
    end

    test "a tampered tx isn't the leaf its BUMP names" do
      RealHeaders.insert(814_435)
      {:ok, beef} = Reader.parse(brc62())
      [bump] = beef.bumps
      [parent, _payment] = beef.transactions

      # The last byte of the lock time: still a tx, now with another txid.
      size = byte_size(parent.raw) - 1
      <<head::binary-size(size), byte>> = parent.raw
      tampered = <<head::binary, Bitwise.bxor(byte, 1)>>

      {:ok, answer} = BeefVerifier.verify(Beef.encode([bump], [{tampered, 0}]))

      assert answer.status == :failed
      assert answer.reason == :not_in_bump
    end

    test "a tampered sibling misses the root" do
      RealHeaders.insert(814_435)
      {:ok, beef} = Reader.parse(brc62())
      [%{path: [level_0 | rest]} = bump] = beef.bumps
      [parent, payment] = beef.transactions

      changed =
        Enum.map(level_0, fn
          %{txid: false, hash: hash} = leaf when is_binary(hash) ->
            %{leaf | hash: :crypto.hash(:sha256, hash)}

          leaf ->
            leaf
        end)

      bytes =
        Beef.encode([%{bump | path: [changed | rest]}], [{parent.raw, 0}, {payment.raw, nil}])

      {:ok, answer} = BeefVerifier.verify(bytes)

      assert [%{status: :failed, reason: :root_mismatch}, _] = answer.transactions
    end

    test "a BUMP with a node missing is incomplete" do
      raw = tx(prev())
      bump = %{height: 5, path: [[leaf(0, sha256d(raw), true), leaf(4, prev())], [], []]}
      bytes = Beef.encode([bump], [{raw, 0}])

      assert %{status: :failed, reason: :incomplete} =
               evaluate(bytes, %{5 => header(String.duplicate("0", 64))})
    end
  end

  describe "a proof must fit the block" do
    test "a tree height that isn't this block's" do
      {:ok, beef} = Reader.parse(brc62())
      headers = %{814_435 => header(@brc62_root, %{num_tx: 106})}
      assert [%{status: :proven} | _] = BeefVerifier.evaluate(beef, headers, 900_000).transactions

      for wrong <- [64, 129, 4_000] do
        headers = %{814_435 => header(@brc62_root, %{num_tx: wrong})}

        assert [%{status: :failed, reason: :tree_height_mismatch} | _] =
                 BeefVerifier.evaluate(beef, headers, 900_000).transactions
      end
    end

    test "a block whose tx count we don't have is judged by the root alone" do
      {:ok, beef} = Reader.parse(brc62())

      for num_tx <- [nil, 0] do
        headers = %{814_435 => header(@brc62_root, %{num_tx: num_tx})}

        assert [%{status: :proven} | _] =
                 BeefVerifier.evaluate(beef, headers, 900_000).transactions
      end
    end

    test "a copy of the last tx reports its real position, not the phantom one" do
      # Three txs: the last pairs with itself, so a leaf at offset 3 climbs to the
      # same root as offset 2. Bitcoin's duplicate-leaf ambiguity (CVE-2012-2459).
      raw = tx(prev())
      c = sha256d(raw)
      [a, b] = [prev(2), prev(3)]
      root = sha256d(sha256d(a <> b) <> sha256d(c <> c))
      bump = %{height: 5, path: [[leaf(3, c, true), leaf(2, c)], [leaf(0, sha256d(a <> b))]]}

      answer =
        evaluate(Beef.encode([bump], [{raw, 0}]), %{5 => header(display(root), %{num_tx: 3})})

      assert [%{status: :proven, index: 2}] = answer.transactions
    end

    test "an offset past the block's count is refused even when the root matches" do
      raw = tx(prev())
      c = sha256d(raw)
      a = prev(2)
      root = sha256d(a <> c)

      bump = %{height: 5, path: [[leaf(0, a), leaf(1, c, true)]]}

      answer =
        evaluate(Beef.encode([bump], [{raw, 0}]), %{5 => header(display(root), %{num_tx: 1})})

      assert [%{status: :failed, reason: :offset_past_block}] = answer.transactions
    end

    test "a 64-byte tx can't pose as an inner node" do
      # 64 bytes that parse as a tx: the shape an inner node's preimage would need.
      raw =
        <<1::little-32, 1, prev()::binary, 0::little-32, 0, 0::little-32, 1, 0::little-64, 4,
          0x51, 0x51, 0x51, 0x51, 0::little-32>>

      assert byte_size(raw) == 64

      bump = %{height: 5, path: [[leaf(0, sha256d(raw), true)]]}
      answer = evaluate(Beef.encode([bump], [{raw, 0}]), %{5 => header(display(sha256d(raw)))})

      assert [%{status: :failed, reason: :ambiguous_64_byte_tx}] = answer.transactions
    end
  end

  describe "ancestry" do
    test "anchoring carries through a chain of txs with no BUMP" do
      a = tx(prev())
      b = a |> Reader.txid() |> internal() |> tx()
      c = b |> Reader.txid() |> internal() |> tx()
      bump = %{height: 5, path: [[leaf(0, sha256d(a), true)]]}

      answer =
        evaluate(
          Beef.encode([bump], [{a, 0}, {b, nil}, {c, nil}]),
          %{5 => header(display(sha256d(a)))}
        )

      assert Enum.map(answer.transactions, & &1.status) == [:proven, :anchored, :anchored]
      assert answer.status == :anchored
    end

    test "a tx with a good proof stands, whatever an ancestor's evidence does" do
      bad = tx(prev())
      good = bad |> Reader.txid() |> internal() |> tx()

      bumps = [
        %{height: 5, path: [[leaf(0, sha256d(bad), true)]]},
        %{height: 6, path: [[leaf(0, sha256d(good), true)]]}
      ]

      answer =
        evaluate(Beef.encode(bumps, [{bad, 0}, {good, 1}]), %{
          5 => header(String.duplicate("0", 64)),
          6 => header(display(sha256d(good)))
        })

      assert answer.status == :proven
      assert Enum.map(answer.transactions, & &1.status) == [:failed, :proven]
      assert answer.proven == [Reader.txid(good)]
    end

    test "a BUMP no tx uses is named, not silently dropped" do
      raw = tx(prev())

      bumps = [
        %{height: 5, path: [[leaf(0, sha256d(raw), true)]]},
        %{height: 6, path: [[leaf(0, prev(7), true)]]}
      ]

      answer = evaluate(Beef.encode(bumps, [{raw, 0}]), %{5 => header(display(sha256d(raw)))})

      assert answer.unused_bumps == [1]
    end
  end

  describe "round trip" do
    setup do
      RpcStub.setup()
      FirstSpendFixtures.insert_first_spend()

      # The fixture's blocks, given their real headers.
      for height <- [9, 170] do
        fixture_hash = height |> Integer.to_string() |> String.pad_leading(64, "b")
        real = RealHeaders.fields(height)

        Repo.update_all(
          Ecto.Query.from(t in "transactions", where: t.block_hash == ^fixture_hash),
          set: [block_hash: real.hash]
        )

        Repo.get_by!(Block, height: height)
        |> Ecto.Changeset.change(Map.put(real, :nextblockhash, nil))
        |> Repo.update!()
      end

      :ok
    end

    test "our own BEEF verifies, parent and subject both proven" do
      {:ok, built} = Beef.build(FirstSpendFixtures.first_spend())
      {:ok, answer} = built.beef |> Base.decode16!(case: :lower) |> BeefVerifier.verify()

      assert answer.status == :proven
      assert answer.format == "beef_v1"
      assert answer.subject_txid == FirstSpendFixtures.first_spend()
      assert answer.block_height == 170
      assert answer.confirmations == 1

      assert answer.proven == [FirstSpendFixtures.coinbase_9(), FirstSpendFixtures.first_spend()]
    end

    test "our own Atomic BEEF verifies, holding the tx and its BUMP alone" do
      txid = FirstSpendFixtures.first_spend()
      {:ok, built} = Beef.build(txid, format: :atomic)

      assert built.format == :atomic
      assert built.transactions == [txid]
      assert built.complete

      bytes = Base.decode16!(built.beef, case: :lower)
      assert {:ok, %{atomic: true, subject: ^txid, transactions: [_]}} = Beef.parse(bytes)

      {:ok, answer} = BeefVerifier.verify(bytes)

      assert answer.status == :proven
      assert answer.format == "atomic_beef_v1"
      assert answer.subject_txid == FirstSpendFixtures.first_spend()
    end
  end
end
