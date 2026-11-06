defmodule Bitblocks.BapTest do
  @moduledoc """
  #32: BAP identities. Records are signed here with real keys and the wallet's
  own script format, so `Bitblocks.Aip` checks them as it checks the chain.
  """
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.{Aip, Bap, Repo}
  alias Bitblocks.Bap.Record
  alias Bitblocks.Chain.{Transaction, TxPipeline}

  @vectors "test/support/data/vectors/bap_id_v1.json"
           |> File.read!()
           |> Jason.decode!()

  defp key do
    privkey = BSV.PrivKey.new()
    %{privkey: privkey, address: address(privkey)}
  end

  defp address(privkey) do
    privkey |> BSV.PubKey.from_privkey() |> BSV.Address.from_pubkey() |> BSV.Address.to_string()
  end

  # An output as a wallet writes it: the fields, then an AIP over everything to
  # their left, ending in "|".
  defp signed(fields, %{privkey: privkey, address: address}, opts \\ []) do
    message =
      opts[:message] || IO.iodata_to_binary([<<0x6A>>, opts[:signed_fields] || fields, "|"])

    signature = BSV.Message.sign(message, privkey, encoding: :raw)
    signature = if opts[:bad_signature], do: flip(signature), else: signature

    %BSV.TxOut{
      satoshis: 0,
      script: %BSV.Script{
        chunks:
          [:OP_FALSE, :OP_RETURN] ++
            fields ++
            ["|", Aip.prefix(), "BITCOIN_ECDSA", address, signature] ++ (opts[:indexes] || [])
      }
    }
  end

  defp flip(<<head::binary-40, byte, rest::binary>>) do
    <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>
  end

  defp id(bap_id, declared, signer, opts \\ []),
    do: signed([Bap.prefix(), "ID", bap_id, declared.address], signer, opts)

  defp alias_record(bap_id, profile, signer, opts \\ []) do
    json = if is_binary(profile), do: profile, else: Jason.encode!(profile)
    signed([Bap.prefix(), "ALIAS", bap_id, json], signer, opts)
  end

  # Publishes outputs in a tx at `height`, as a stored row, through the step.
  defp publish(outputs, height, offset \\ nil) do
    block = Repo.get_by(Bitblocks.Chain.Block, height: height) || block_fixture(%{height: height})
    in_tx = %BSV.TxIn{outpoint: %BSV.OutPoint{hash: :crypto.strong_rand_bytes(32), vout: 0}}
    tx = %BSV.Tx{inputs: [in_tx], outputs: outputs}
    raw = BSV.Tx.to_binary(tx, encoding: :hex)
    signers = for %BSV.TxOut{script: s} <- outputs, a <- Aip.verified_signers(s.chunks), do: a

    row =
      transaction_fixture(%{
        txid: BSV.Tx.get_txid(tx),
        raw: raw,
        block_height: height,
        block_hash: block.hash,
        aip_signers: Enum.uniq(signers),
        protocols: ["AIP"]
      })

    row =
      if offset,
        do: row |> Ecto.Changeset.change(raw_offset: offset) |> Repo.update!(),
        else: row

    Bap.index(row)
    row
  end

  setup do
    root = key()
    %{root: root, bap_id: Bap.bap_id_of(root.address), one: key(), two: key(), three: key()}
  end

  describe "the vectors" do
    test "every BAP ID in bap_id_v1.json is reproduced from its address" do
      for %{"address" => address, "bap_id" => bap_id} <- @vectors["ids"] do
        assert Bap.bap_id_of(address) == bap_id
      end
    end

    test "each vector's address is its pubkey's" do
      for %{"pubkey" => hex, "address" => address} <- @vectors["ids"] do
        pubkey = BSV.PubKey.from_binary!(hex, encoding: :hex)
        assert pubkey |> BSV.Address.from_pubkey() |> BSV.Address.to_string() == address
      end
    end

    test "the vector's ID script reads as the record it describes, unsigned so not counted" do
      %{"bap_id" => bap_id, "script_hex" => hex} = @vectors["id_record"]
      script = BSV.Script.from_binary!(hex, encoding: :hex)

      assert [:OP_FALSE, :OP_RETURN, prefix, "ID", ^bap_id, address] = script.chunks
      assert prefix == Bap.prefix()
      assert address =~ ~r/\A1/

      in_tx = %BSV.TxIn{outpoint: %BSV.OutPoint{hash: <<0::256>>, vout: 0}}
      tx = %BSV.Tx{inputs: [in_tx], outputs: [%BSV.TxOut{satoshis: 0, script: script}]}
      assert Bap.records("a", BSV.Tx.to_binary(tx, encoding: :hex)) == []
    end
  end

  describe "index/1" do
    test "stores what each record says, and who signed it", ctx do
      row = publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)

      assert [%Record{} = record] = Repo.all(from r in Record, where: r.txid == ^row.txid)
      assert record.action == "ID"
      assert record.bap_id == ctx.bap_id
      assert record.address == ctx.one.address
      assert record.signer == ctx.root.address
      assert record.vout == 0
      assert record.version == TxPipeline.Steps.IndexBap.version()
    end

    test "is idempotent, and a no-op on a tx with no AIP signer", ctx do
      row = publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)
      assert Bap.index(row) == 0
      assert Repo.aggregate(Record, :count) == 1

      assert Bap.index(%{row | aip_signers: []}) == 0
      assert Bap.index(%Transaction{txid: "x", raw: nil}) == 0
    end

    test "a record with a bad AIP signature is not stored", ctx do
      publish([id(ctx.bap_id, ctx.one, ctx.root, bad_signature: true)], 700_000)
      assert Repo.aggregate(Record, :count) == 0
      assert Bap.identity(ctx.bap_id) == nil
    end

    test "a signature over other fields than the record's is not stored", ctx do
      other = [Bap.prefix(), "ID", ctx.bap_id, ctx.two.address]
      publish([id(ctx.bap_id, ctx.one, ctx.root, signed_fields: other)], 700_000)
      assert Repo.aggregate(Record, :count) == 0
    end

    test "an AIP that signs chosen fields must cover the record's", ctx do
      fields = [Bap.prefix(), "ID", ctx.bap_id, ctx.one.address]

      # Fields 1 and 2 only (prefix, action): the id and address aren't signed.
      partial = signed(fields, ctx.root, indexes: ["1", "2"], message: Bap.prefix() <> "ID")
      assert Aip.verified_signers(partial.script.chunks) == [ctx.root.address]

      publish([partial], 700_000)
      assert Repo.aggregate(Record, :count) == 0

      # Every field, by index, is as good as signing all of them.
      full =
        signed(fields, ctx.root,
          indexes: ["1", "2", "3", "4"],
          message: IO.iodata_to_binary(fields)
        )

      publish([full], 700_001)
      assert Repo.aggregate(Record, :count) == 1
    end

    test "a poison record costs nothing and fails nothing", ctx do
      prefix = Bap.prefix()

      for fields <- [
            [prefix, "ID", ctx.bap_id],
            [prefix, "ID", "not base58 0OIl", ctx.one.address],
            [prefix, "ID", String.duplicate("1", 500), ctx.one.address],
            [prefix, "ATTEST", "short", "0"],
            [prefix, "ATTEST", String.duplicate("a", 64), "not a number"],
            [prefix, "NONSENSE", ctx.bap_id, "x"],
            [prefix, <<0, 255>>, ctx.bap_id, "x"]
          ] do
        publish([signed(fields, ctx.root)], 700_000)
      end

      assert Repo.aggregate(Record, :count) == 0
    end

    test "a profile Postgres can't hold is an ALIAS with no profile, not a failure", ctx do
      publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)

      for json <- [
            ~s({"name":"a\\u0000b"}),
            "not json",
            "[1,2]",
            <<"{\"name\":\"", 255, "\"}">>,
            String.duplicate("x", 70_000)
          ] do
        publish([alias_record(ctx.bap_id, json, ctx.one)], 700_001)
      end

      assert Repo.aggregate(from(r in Record, where: not is_nil(r.profile)), :count) == 0
      assert %{current_profile: nil} = Bap.identity(ctx.bap_id)
    end

    test "garbage hex is no record, not an error" do
      assert Bap.records("x", "zz") == []
      assert Bap.records("x", "00") == []
    end

    test "runs in the pipeline, as one module and one line" do
      assert TxPipeline.Steps.IndexBap in TxPipeline.steps(:tx)
    end
  end

  describe "identity/1" do
    test "an unknown identity is nil" do
      assert Bap.identity("2Ny5b5yyzSedzcnhK4H3w2xS9iR3") == nil
    end

    test "reads the first record, the current address and the current profile", ctx do
      first = publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)
      publish([alias_record(ctx.bap_id, %{name: "Ada", image: "1sat://abc_0"}, ctx.one)], 700_010)

      identity = Bap.identity(ctx.bap_id)

      assert identity.root_address == ctx.root.address
      assert identity.current_address == ctx.one.address
      assert %{txid: txid, block_height: 700_000} = identity.first_record
      assert txid == first.txid
      assert identity.rotations == []
      assert %{block_height: 700_010, profile: profile} = identity.current_profile
      assert profile == %{"name" => "Ada", "image" => "1sat://abc_0"}
    end

    test "an ID and its ALIAS in one tx: a wallet's first publish", ctx do
      publish(
        [
          alias_record(ctx.bap_id, %{name: "Ada"}, ctx.one),
          id(ctx.bap_id, ctx.one, ctx.root)
        ],
        700_000
      )

      assert %{current_address: address, current_profile: %{profile: %{"name" => "Ada"}}} =
               Bap.identity(ctx.bap_id)

      assert address == ctx.one.address
    end

    test "a rotated identity reports the first record's height, not the latest", ctx do
      publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)
      publish([id(ctx.bap_id, ctx.two, ctx.one)], 710_000)
      publish([id(ctx.bap_id, ctx.three, ctx.root)], 720_000)

      identity = Bap.identity(ctx.bap_id)

      assert identity.first_record.block_height == 700_000
      assert identity.current_address == ctx.three.address

      assert [
               %{block_height: 710_000, signed_by: "previous"},
               %{block_height: 720_000, signed_by: "root"}
             ] = identity.rotations
    end

    test "nobody but the root can start an identity, however early", ctx do
      thief = key()
      publish([id(ctx.bap_id, thief, thief)], 690_000)
      assert Bap.identity(ctx.bap_id) == nil

      publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)

      identity = Bap.identity(ctx.bap_id)
      assert identity.first_record.block_height == 700_000
      assert identity.current_address == ctx.one.address
      assert [%{reason: "not signed by the root key"}] = identity.rejected
    end

    test "a rotation by a stranger or a rotated-away key isn't accepted", ctx do
      publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)
      publish([id(ctx.bap_id, ctx.two, ctx.one)], 710_000)

      stranger = key()
      publish([id(ctx.bap_id, stranger, stranger)], 720_000)
      # ctx.one rotated away at 710,000.
      publish([id(ctx.bap_id, ctx.three, ctx.one)], 730_000)

      identity = Bap.identity(ctx.bap_id)
      assert identity.current_address == ctx.two.address
      assert length(identity.rotations) == 1
      assert length(identity.rejected) == 2
    end

    test "a record sharing a block is ordered by its place in the block", ctx do
      publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)
      # The rotation is second in the block, whatever its txid.
      publish([id(ctx.bap_id, ctx.three, ctx.two)], 700_001, 900)
      publish([id(ctx.bap_id, ctx.two, ctx.one)], 700_001, 100)

      assert %{current_address: address, rotations: [_, _]} = Bap.identity(ctx.bap_id)
      assert address == ctx.three.address
    end

    test "the newest accepted ALIAS wins, by chain order and not by what it claims", ctx do
      publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)
      publish([alias_record(ctx.bap_id, %{name: "New", publishedAt: 1}, ctx.one)], 700_020)
      publish([alias_record(ctx.bap_id, %{name: "Old", publishedAt: 9}, ctx.one)], 700_010)

      assert %{current_profile: %{profile: %{"name" => "New"}}} = Bap.identity(ctx.bap_id)
    end

    test "an ALIAS by a stranger or a rotated-away key is not current", ctx do
      publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)
      publish([alias_record(ctx.bap_id, %{name: "Mine"}, ctx.one)], 700_010)
      publish([id(ctx.bap_id, ctx.two, ctx.one)], 700_020)
      publish([alias_record(ctx.bap_id, %{name: "Stale key"}, ctx.one)], 700_030)
      publish([alias_record(ctx.bap_id, %{name: "Stranger"}, key())], 700_040)

      identity = Bap.identity(ctx.bap_id)
      assert %{profile: %{"name" => "Mine"}} = identity.current_profile
      assert length(identity.rejected) == 2
    end

    test "the root can always speak: rotating back from a stolen key", ctx do
      publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)
      stolen = key()
      publish([id(ctx.bap_id, stolen, ctx.one)], 700_010)
      publish([id(ctx.bap_id, ctx.two, ctx.root)], 700_020)

      assert %{current_address: address} = Bap.identity(ctx.bap_id)
      assert address == ctx.two.address
    end

    test "ignores a record left on an orphaned block", ctx do
      publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)
      row = publish([id(ctx.bap_id, ctx.two, ctx.one)], 700_010)

      row |> Ecto.Changeset.change(block_hash: "orphaned-hash") |> Repo.update!()

      assert %{current_address: address} = Bap.identity(ctx.bap_id)
      assert address == ctx.one.address
    end

    test "follows a row the reorg moved to the new chain", ctx do
      row = publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)
      moved = block_fixture(%{height: 700_005})

      row
      |> Ecto.Changeset.change(block_hash: moved.hash, block_height: 700_005)
      |> Repo.update!()

      assert %{first_record: %{block_height: 700_005}} = Bap.identity(ctx.bap_id)
    end
  end

  describe "attestations/1 and by_address/1" do
    setup ctx do
      publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)
      publish([id(ctx.bap_id, ctx.two, ctx.one)], 700_020)
      :ok
    end

    defp attest(hash, signer, action \\ "ATTEST"),
      do: signed([Bap.prefix(), action, hash, "0"], signer)

    test "lists what the identity made, with revocations by keys it held", ctx do
      kept = String.duplicate("a", 64)
      revoked = String.duplicate("b", 64)
      stale = String.duplicate("c", 64)

      publish([attest(kept, ctx.one)], 700_010)
      publish([attest(revoked, ctx.two)], 700_030)
      publish([attest(revoked, ctx.two, "REVOKE")], 700_040)
      # ctx.one rotated away at 700,020.
      publish([attest(stale, ctx.one)], 700_050)

      assert %{made: made} = Bap.attestations(ctx.bap_id)

      assert %{^kept => false, ^revoked => true} =
               Map.new(made, &{&1.attestation_hash, &1.revoked})

      refute Enum.any?(made, &(&1.attestation_hash == stale))
    end

    test "unknown identity is nil" do
      assert Bap.attestations("2Ny5b5yyzSedzcnhK4H3w2xS9iR3") == nil
    end

    test "finds the identities an address signs for, and which is current", ctx do
      assert [%{bap_id: id, current: false}] = Bap.by_address(ctx.one.address)
      assert id == ctx.bap_id
      assert [%{current: true}] = Bap.by_address(ctx.two.address)
      assert [%{current: false}] = Bap.by_address(ctx.root.address)
      assert Bap.by_address(key().address) == []
    end

    test "a record that names an address but isn't accepted finds nothing", ctx do
      stranger = key()
      publish([id(ctx.bap_id, stranger, stranger)], 700_060)
      assert Bap.by_address(stranger.address) == []
    end
  end

  describe "the backfill" do
    alias Bitblocks.Chain.TxPipeline.BapBackfill

    test "dry run counts, apply stores, a rerun finds nothing", ctx do
      row = publish([id(ctx.bap_id, ctx.one, ctx.root)], 700_000)
      Repo.delete_all(Record)

      dry = BapBackfill.run(699_999, 700_001)
      assert %{applied: false, rows_examined: 1, rows_changed: 1, outcome: "ok"} = dry
      assert Repo.aggregate(Record, :count) == 0

      assert %{applied: true, rows_changed: 1} = BapBackfill.run(699_999, 700_001, apply: true)
      assert [%Record{txid: txid}] = Repo.all(Record)
      assert txid == row.txid

      assert %{rows_changed: 0} = BapBackfill.run(699_999, 700_001, apply: true)
    end

    test "records its run, and can be started as a chain" do
      assert %{derivation: "bap", run_id: id} = BapBackfill.run(1, 2)
      assert is_integer(id)
      assert "bap" in Bitblocks.BackfillChains.derivations()
    end
  end
end
