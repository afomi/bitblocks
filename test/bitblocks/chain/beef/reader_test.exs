defmodule Bitblocks.Chain.Beef.ReaderTest do
  # No DataCase, on purpose: the reader has no database, and this file proves it.
  use ExUnit.Case, async: true

  alias Bitblocks.Chain.Beef
  alias Bitblocks.Chain.Beef.Reader

  @fixtures Path.expand("../../../support/fixtures/brc", __DIR__)

  @v1 <<0x01, 0x00, 0xBE, 0xEF>>
  @v2 <<0x02, 0x00, 0xBE, 0xEF>>
  @atomic <<0x01, 0x01, 0x01, 0x01>>

  defp hex_vector(name) do
    @fixtures |> Path.join(name) |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
  end

  defp json_vector(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp unhex(hex), do: Base.decode16!(hex, case: :lower)

  defp internal(txid), do: txid |> unhex() |> reverse()

  defp reverse(bytes),
    do: bytes |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  # A minimal tx spending `prev` (internal bytes), told apart by `tag`.
  defp tx(prev, tag \\ 0) do
    <<1::little-32, 1, prev::binary, tag::little-32, 0, 0xFFFFFFFF::little-32, 1, 1000::little-64,
      1, 0x51, 0::little-32>>
  end

  defp prev(tag \\ 1), do: :crypto.hash(:sha256, <<tag>>)

  # Block 7, tree height 1: a tx and its duplicate.
  defp bump(raw) do
    hash = :crypto.hash(:sha256, :crypto.hash(:sha256, raw))
    <<7, 1, 2, 0, 2, hash::binary, 1, 1>>
  end

  defp small_bump, do: <<7, 1, 2, 0, 2, prev()::binary, 1, 1>>

  describe "BRC-74 example" do
    setup do
      bytes = hex_vector("brc74_bump.hex")
      {:ok, bump, ""} = Reader.parse_bump(bytes)
      %{bytes: bytes, bump: bump}
    end

    test "writes back byte for byte", %{bump: bump, bytes: bytes} do
      assert bump.height == 813_706
      assert Beef.encode_bump(bump) == bytes
    end

    test "all three of the spec's txids climb to its root, at their own offsets", %{bump: bump} do
      root = "57aab6e6fb1b697174ffb64e062c4728f2ffd33ddcfa02a43b64d8cd29b483b4"

      for txid <- [
            "304e737fdfcb017a1a322e78b067ecebb5e07b44f0a36ed1f01264d2014f7711",
            "d888711d588021e588984e8278a2decf927298173a06737066e43f3e75534e00",
            "98c9c5dd79a18f40837061d5e0395ffb52e700a2689e641d19f053fc9619445e"
          ] do
        assert {:ok, ^root, offset} = Reader.root(bump, txid)
        assert is_integer(offset)
      end
    end

    test "a txid that isn't a leaf has no root", %{bump: bump} do
      assert Reader.root(bump, String.duplicate("a", 64)) == {:error, :not_in_bump}
    end
  end

  describe "BRC-62 example" do
    setup do
      bytes = hex_vector("brc62_beef.hex")
      {:ok, beef} = Reader.parse(bytes)
      %{bytes: bytes, beef: beef}
    end

    test "reads as V1 with the payment as its subject", %{beef: beef} do
      assert %{format: :v1, atomic: false} = beef
      assert [%{bump_index: 0}, %{bump_index: nil, txid: subject}] = beef.transactions
      assert beef.subject == subject
    end

    test "the parent's BUMP reaches the root in block 814435's real header", %{beef: beef} do
      [parent, payment] = beef.transactions
      [bump] = beef.bumps

      assert payment.parents == [parent.txid]

      assert {:ok, "bb6f640cc4ee56bf38eb5a1969ac0c16caa2d3d202b22bf3735d10eec0ca6e00", _} =
               Reader.root(bump, parent.txid)
    end

    test "writes back byte for byte", %{beef: beef, bytes: bytes} do
      assert Beef.encode(
               beef.bumps,
               Enum.map(beef.transactions, &{&1.raw, &1.bump_index})
             ) == bytes
    end
  end

  describe "shared vectors" do
    test "a real mainnet BUMP from WhatsOnChain: bytes, txid and root" do
      vector = json_vector("woc_mainnet_v1.json")
      bytes = unhex(vector["bump"])

      assert {:ok, bump, ""} = Reader.parse_bump(bytes)
      assert Beef.encode_bump(bump) == bytes
      assert bump.height == vector["blockHeight"]
      assert Reader.txid(unhex(vector["rawTx"])) == vector["txid"]

      root = vector["merkleRoot"]
      assert {:ok, ^root, _} = Reader.root(bump, vector["txid"])
    end

    test "a BEEF V1 written by the SDK: subject, parents, anchor and bytes" do
      vector = json_vector("vault_beef_v1.json")
      bytes = unhex(vector["unsignedBeef"])

      assert {:ok, beef} = Reader.parse(bytes)
      assert beef.subject == vector["unsignedTxid"]

      subject = List.last(beef.transactions)
      [mined, unconfirmed] = vector["facts"]["inputs"]
      assert subject.parents == [mined["txid"], unconfirmed["txid"]]

      index = Enum.find(beef.transactions, &(&1.txid == mined["txid"])).bump_index
      bump = Enum.at(beef.bumps, index)
      root = mined["anchor"]["merkleRoot"]

      assert bump.height == mined["anchor"]["blockHeight"]
      assert {:ok, ^root, _} = Reader.root(bump, mined["txid"])

      assert Beef.encode(
               beef.bumps,
               Enum.map(beef.transactions, &{&1.raw, &1.bump_index})
             ) == bytes
    end

    test "Atomic BEEF written by the SDK: our writer gives the same bytes" do
      vector = json_vector("beef_sdk_v1.json")
      bytes = unhex(vector["brc62_atomic"])

      assert {:ok, beef} = Reader.parse(bytes)
      assert %{format: :v1, atomic: true} = beef
      assert beef.subject == vector["brc62_subject"]

      assert Beef.atomic(hex_vector("brc62_beef.hex"), vector["brc62_subject"]) == bytes
    end

    test "Atomic BEEF around the two-input BEEF" do
      vector = json_vector("beef_sdk_v1.json")

      assert {:ok, %{atomic: true, subject: subject, transactions: txs}} =
               Reader.parse(unhex(vector["atomic_v1"]))

      assert subject == vector["subject"]
      assert List.last(txs).txid == subject
    end

    test "BEEF V2 written by the SDK reads as the same transactions as its V1" do
      sdk = json_vector("beef_sdk_v1.json")
      v1 = json_vector("vault_beef_v1.json")

      assert {:ok, %{format: :v2} = from_v2} = Reader.parse(unhex(sdk["v2"]))
      {:ok, from_v1} = Reader.parse(unhex(v1["unsignedBeef"]))

      assert Enum.map(from_v2.transactions, & &1.txid) ==
               Enum.map(from_v1.transactions, & &1.txid)

      assert from_v2.subject == from_v1.subject
      assert from_v2.bumps == from_v1.bumps
    end

    test "a BEEF V2 txid-only entry carries the txid and nothing to hash" do
      sdk = json_vector("beef_sdk_v1.json")

      assert {:ok, %{format: :v2, transactions: [known, _payment]}} =
               Reader.parse(unhex(sdk["brc62_v2_txid_only"]))

      assert %{txid_only: true, raw: nil} = known
      assert known.txid == sdk["brc62_parent"]
    end
  end

  describe "no input crashes it" do
    test "every truncation of a real BEEF is refused" do
      bytes = hex_vector("brc62_beef.hex")

      for size <- 0..(byte_size(bytes) - 1) do
        assert {:error, reason} = Reader.parse(binary_part(bytes, 0, size))
        assert is_atom(reason)
      end
    end

    test "every truncation of real Atomic and V2 BEEF is refused" do
      sdk = json_vector("beef_sdk_v1.json")

      for key <- ["atomic_v1", "v2", "brc62_v2_txid_only"] do
        bytes = unhex(sdk[key])

        for size <- 0..(byte_size(bytes) - 1) do
          assert {:error, _} = Reader.parse(binary_part(bytes, 0, size))
        end
      end
    end

    test "any single byte changed gives an answer, never a crash" do
      bytes = hex_vector("brc62_beef.hex")

      for position <- 0..(byte_size(bytes) - 1), mask <- [0x01, 0x80, 0xFF] do
        <<head::binary-size(position), byte, tail::binary>> = bytes
        result = Reader.parse(<<head::binary, Bitwise.bxor(byte, mask), tail::binary>>)
        assert match?({:ok, %{}}, result) or match?({:error, _}, result)
      end
    end

    test "random tails on each version give an answer, never a crash" do
      :rand.seed(:exsss, {7, 11, 13})

      for head <- [@v1, @v2, <<@atomic::binary, 0::256, @v1::binary>>], size <- 0..200 do
        tail = :rand.bytes(size)
        result = Reader.parse(head <> tail)
        assert match?({:ok, %{}}, result) or match?({:error, _}, result)
      end
    end
  end

  describe "the envelope" do
    test "anything else is refused by name" do
      assert Reader.parse(<<1, 0, 0, 0, 0>>) == {:error, :unknown_format}
      assert Reader.parse("") == {:error, :truncated}
      assert Reader.parse(<<0x01, 0x00>>) == {:error, :truncated}
    end

    test "bytes after the end are refused" do
      assert Reader.parse(hex_vector("brc62_beef.hex") <> <<0>>) == {:error, :trailing_bytes}
    end

    test "a BEEF with no transactions is refused" do
      assert Reader.parse(<<@v1::binary, 0, 0>>) == {:error, :no_transactions}
    end

    test "Atomic BEEF can't wrap Atomic BEEF" do
      inner = <<@atomic::binary, 0::256, @v1::binary, 0, 0>>
      assert Reader.parse(<<@atomic::binary, 0::256, inner::binary>>) == {:error, :unknown_format}
    end
  end

  describe "limits" do
    test "over max_bytes is refused before reading" do
      assert Reader.parse(hex_vector("brc62_beef.hex"), max_bytes: 10) == {:error, :too_large}
    end

    test "a bump count past the limit is refused without looking for them" do
      assert Reader.parse(<<@v1::binary, 0xFD, 0x00, 0x10>>) == {:error, :too_many_bumps}

      assert Reader.parse(<<@v1::binary, 0xFF, 0xFFFFFFFFFFFFFFFF::little-64>>) ==
               {:error, :too_many_bumps}
    end

    test "a tx count past the limit is refused without looking for them" do
      assert Reader.parse(<<@v1::binary, 0, 0xFE, 0xFFFFFF::little-32>>) ==
               {:error, :too_many_transactions}
    end

    test "too many leaves are refused" do
      bytes = <<@v1::binary, 1, small_bump()::binary, 1, tx(prev())::binary, 1, 0>>
      assert Reader.parse(bytes, max_leaves: 1) == {:error, :too_many_leaves}
    end

    test "a script length larger than the input is truncation, not an allocation" do
      raw = <<1::little-32, 1, 0::256, 0::little-32, 0xFF, 0xFFFFFFFFFFFFFFFF::little-64>>
      assert Reader.parse(<<@v1::binary, 0, 1, raw::binary>>) == {:error, :truncated}
    end
  end

  describe "VarInts" do
    test "a value that fits a shorter form is refused" do
      assert Reader.parse(<<@v1::binary, 0xFD, 1, 0>>) == {:error, :varint_not_minimal}
      assert Reader.parse(<<@v1::binary, 0xFE, 1, 0, 0, 0>>) == {:error, :varint_not_minimal}

      assert Reader.parse(<<@v1::binary, 0xFF, 1::little-64>>) == {:error, :varint_not_minimal}
    end
  end

  describe "BUMPs" do
    defp bump_error(bump) do
      {:error, reason} = Reader.parse_bump(bump)
      reason
    end

    test "tree heights outside 1..64" do
      assert bump_error(<<7, 0>>) == :tree_height_out_of_range
      assert bump_error(<<7, 65>>) == :tree_height_out_of_range
    end

    test "a block height past 2^32 - 1" do
      assert bump_error(<<0xFF, 0x100000000::little-64, 1>>) == :block_height_out_of_range
    end

    test "no leaves at level 0" do
      assert bump_error(<<7, 1, 0>>) == :empty_level
    end

    test "an offset that doesn't fit the tree" do
      assert bump_error(<<7, 1, 1, 2, 0, prev()::binary>>) == :offset_out_of_range
    end

    test "two leaves at one offset" do
      assert bump_error(<<7, 1, 2, 0, 0, prev()::binary, 0, 0, prev(2)::binary>>) ==
               :duplicate_offset
    end

    test "a flag outside BRC-74" do
      assert bump_error(<<7, 1, 1, 0, 3, prev()::binary>>) == :bad_leaf_flag
    end

    test "a duplicate leaf at an even offset" do
      assert bump_error(<<7, 1, 1, 0, 1>>) == :bad_duplicate_offset
    end

    test "a leaf cut short" do
      assert bump_error(<<7, 1, 1, 0, 0, 1, 2, 3>>) == :truncated
    end

    test "an empty level above 0 is fine: the leaves below compute it" do
      assert {:ok, %{path: [[_, _], []]}, ""} =
               Reader.parse_bump(<<7, 2, 2, 0, 2, prev()::binary, 1, 1, 0>>)
    end
  end

  describe "transactions" do
    test "a tx with no inputs or no outputs" do
      assert Reader.parse(<<@v1::binary, 0, 1, 1::little-32, 0, 1, 0, 0::little-32, 0>>) ==
               {:error, :bad_transaction}

      no_outputs = <<1::little-32, 1, prev()::binary, 0::little-32, 0, 0::little-32, 0>>

      assert Reader.parse(<<@v1::binary, 0, 1, no_outputs::binary, 0::little-32, 0>>) ==
               {:error, :bad_transaction}
    end

    test "Extended Format is refused" do
      marker = <<1::little-32, 0, 0, 0, 0, 0, 0xEF>>
      assert Reader.parse(<<@v1::binary, 0, 1, marker::binary>>) == {:error, :bad_transaction}
    end

    test "a has-BUMP flag other than 0 or 1" do
      assert Reader.parse(<<@v1::binary, 0, 1, tx(prev())::binary, 2>>) ==
               {:error, :bad_transaction_flag}
    end

    test "a BUMP index past the list" do
      bytes = <<@v1::binary, 1, small_bump()::binary, 1, tx(prev())::binary, 1, 1>>
      assert Reader.parse(bytes) == {:error, :bump_index_out_of_range}

      bytes = <<@v1::binary, 0, 1, tx(prev())::binary, 1, 0>>
      assert Reader.parse(bytes) == {:error, :bump_index_out_of_range}
    end

    test "the same tx twice" do
      raw = tx(prev())

      assert Reader.parse(<<@v1::binary, 0, 2, raw::binary, 0, raw::binary, 0>>) ==
               {:error, :duplicate_transaction}
    end

    test "a tx with no BUMP ahead of its parent" do
      parent = tx(prev())
      child = parent |> Reader.txid() |> internal() |> tx()

      assert Reader.parse(<<@v1::binary, 0, 2, child::binary, 0, parent::binary, 0>>) ==
               {:error, :transactions_out_of_order}

      assert {:ok, _} = Reader.parse(<<@v1::binary, 0, 2, parent::binary, 0, child::binary, 0>>)
    end

    test "a tx with a BUMP may come after its parent's child: it stands on its own" do
      parent = tx(prev())
      child = parent |> Reader.txid() |> internal() |> tx()
      bytes = <<@v1::binary, 1, bump(child)::binary, 2, child::binary, 1, 0, parent::binary, 0>>

      assert {:ok, _} = Reader.parse(bytes)
    end

    test "a BEEF V2 tag outside BRC-96" do
      assert Reader.parse(<<@v2::binary, 0, 1, 3>>) == {:error, :bad_transaction_flag}
    end

    test "a coinbase has no parents" do
      raw =
        <<1::little-32, 1, 0::256, 0xFFFFFFFF::little-32, 1, 0, 0::little-32, 1, 0::little-64, 0,
          0::little-32>>

      assert {:ok, %{transactions: [%{coinbase: true, parents: []}]}} =
               Reader.parse(<<@v1::binary, 0, 1, raw::binary, 0>>)
    end
  end

  describe "Atomic BEEF rules (BRC-95)" do
    setup do
      parent = tx(prev())
      child = parent |> Reader.txid() |> internal() |> tx()
      %{parent: parent, child: child}
    end

    test "the subject must be present", %{parent: parent} do
      bytes = <<@atomic::binary, prev()::binary, @v1::binary, 0, 1, parent::binary, 0>>
      assert Reader.parse(bytes) == {:error, :atomic_subject_missing}
    end

    test "the subject and its ancestry read", %{parent: parent, child: child} do
      subject = child |> Reader.txid() |> internal()

      bytes =
        <<@atomic::binary, subject::binary, @v1::binary, 0, 2, parent::binary, 0, child::binary,
          0>>

      assert {:ok, %{atomic: true, subject: txid}} = Reader.parse(bytes)
      assert txid == Reader.txid(child)
    end

    test "ancestry stops at a BUMP: a parent of a proven subject is unrelated", %{
      parent: parent,
      child: child
    } do
      subject = child |> Reader.txid() |> internal()

      bytes =
        <<@atomic::binary, subject::binary, @v1::binary, 1, bump(child)::binary, 2,
          parent::binary, 0, child::binary, 1, 0>>

      assert Reader.parse(bytes) == {:error, :atomic_unrelated_transaction}
    end

    test "a tx outside the subject's ancestry is refused", %{parent: parent} do
      other = tx(prev(9))
      subject = parent |> Reader.txid() |> internal()

      bytes =
        <<@atomic::binary, subject::binary, @v1::binary, 0, 2, other::binary, 0, parent::binary,
          0>>

      assert Reader.parse(bytes) == {:error, :atomic_unrelated_transaction}
    end

    test "the subject cut short" do
      assert Reader.parse(<<@atomic::binary, 1, 2, 3>>) == {:error, :truncated}
    end
  end

  describe "roots" do
    defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))

    defp leaf(offset, hash, txid? \\ false),
      do: %{offset: offset, hash: hash, txid: txid?, duplicate: false}

    defp duplicate(offset), do: %{offset: offset, hash: nil, txid: false, duplicate: true}

    defp display(hash), do: hash |> reverse() |> Base.encode16(case: :lower)

    test "a lone last node pairs with itself" do
      [a, b, c] = Enum.map([1, 2, 3], &sha256d(<<&1>>))
      root = sha256d(sha256d(a <> b) <> sha256d(c <> c))
      bump = %{height: 1, path: [[leaf(2, c, true), duplicate(3)], [leaf(0, sha256d(a <> b))]]}

      assert {:ok, climbed, 2} = Reader.root(bump, display(c))
      assert climbed == display(root)
    end

    test "a node the leaves below imply needn't be stated" do
      [a, b, c, d] = Enum.map([1, 2, 3, 4], &sha256d(<<&1>>))
      root = sha256d(sha256d(a <> b) <> sha256d(c <> d))

      bump = %{
        height: 1,
        path: [[leaf(0, a, true), leaf(1, b), leaf(2, c), leaf(3, d, true)], []]
      }

      for {hash, offset} <- [{a, 0}, {b, 1}, {c, 2}, {d, 3}] do
        assert {:ok, climbed, ^offset} = Reader.root(bump, display(hash))
        assert climbed == display(root)
      end
    end

    test "a missing node is incomplete" do
      a = sha256d(<<1>>)

      assert Reader.root(%{height: 1, path: [[leaf(0, a), leaf(2, a)], []]}, display(a)) ==
               {:error, :incomplete}
    end

    test "the one tx of a block is its own root" do
      a = sha256d(<<1>>)

      assert Reader.root(%{height: 1, path: [[leaf(0, a, true)]]}, display(a)) ==
               {:ok, display(a), 0}
    end

    test "index/1 is reusable across climbs" do
      [a, b] = Enum.map([1, 2], &sha256d(<<&1>>))
      index = Reader.index(%{height: 1, path: [[leaf(0, a), leaf(1, b)]]})

      assert {:ok, root, 0} = Reader.root(index, display(a))
      assert {:ok, ^root, 1} = Reader.root(index, display(b))
    end
  end
end
