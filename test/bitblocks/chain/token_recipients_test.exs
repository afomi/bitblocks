defmodule Bitblocks.Chain.TokenRecipientsTest do
  # #69: who holds an inscribed output, read from its lock on the raw-block
  # path, where the output JSON names no address, and the re-index that fills
  # the rows stored before that worked.
  use Bitblocks.DataCase, async: false
  use Oban.Testing, repo: Bitblocks.Repo

  import Bitblocks.ChainFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.{BackfillChains, ProtocolRegistry, Release, Tokens}
  alias Bitblocks.Chain.{RawBlock, Transaction, TxIngest}
  alias Bitblocks.Chain.TxPipeline.{Steps, TokenRecipientsBackfill}
  alias Bitblocks.Derivations.Run
  alias Bitblocks.Ordinals.Inscription
  alias Bitblocks.ProtocolRegistry.Instance
  alias Bitblocks.Workers.BackfillChainWorker

  # A classic BSV-20 mint from the chain (block 973,900): a 1-sat output with
  # the P2PKH *before* the envelope, which the node calls nonstandard.
  @real_mint_hex "020000000118eb22dd5cdf048df601c46b40b2581679f93e54426695606e1ea2e9b8c16ba5050000006b483045022100ef1ae7fc6fa64dfdcf3facb363b1c8aeb1047fbd85149368ea371774b43050a002200f38c1dbb7dc75b756a9a175e0fc2e1ee5771f12d3711978fb862a60834ca87f41210335ebd8d1c8b8429af9509248b6fb9ad2cf785fcd5c338981ead7f0303bd3f726feffffff0601000000000000006b76a9145a39f76aa8cbc4da680a1daafdd1b0538d38cb4588ac0063036f726451126170706c69636174696f6e2f6273762d323000357b2270223a226273762d3230222c226f70223a226d696e74222c227469636b223a226b75726f222c22616d74223a2231303030227d68e4570000000000001976a91478b32492a3cce463c884a06f02eb30282374930288ac28230000000000001976a9141a7cc744c7488361d21be0fe720d3fce25df414388ac44480000000000001976a9146dbda7ff21fc641efc82b4292ca967616027113888ac00000000000000003f006a223150755161374b36324d694b43747373534c4b79316b683536575755374d74555235035345540361707007666972657361740474797065046d696e748082ba00000000001976a9145a39f76aa8cbc4da680a1daafdd1b0538d38cb4588ac00000000"
  @real_mint_txid "a828d6384c1dbdbc2549c34282901e58805c70209109cf3401d8db8a1d007b7a"
  @real_mint_pkh Base.decode16!("5a39f76aa8cbc4da680a1daafdd1b0538d38cb45", case: :lower)

  @pkh :binary.copy(<<0xBB>>, 20)
  @cosigner_key <<2>> <> :binary.copy(<<0xCC>>, 32)
  @p2pkh [:OP_DUP, :OP_HASH160, @pkh, :OP_EQUALVERIFY, :OP_CHECKSIG]
  @cosign [
    :OP_DUP,
    :OP_HASH160,
    @pkh,
    :OP_EQUALVERIFY,
    :OP_CHECKSIGVERIFY,
    @cosigner_key,
    :OP_CHECKSIG
  ]
  @other_lock [:OP_DROP, :OP_1]

  defp address(pkh), do: BSV.Address.to_string(%BSV.Address{pubkey_hash: pkh})
  defp owner, do: address(@pkh)
  defp cosigner_hex, do: Base.encode16(@cosigner_key, case: :lower)

  defp envelope(body) do
    [:OP_FALSE, :OP_IF, "ord", :OP_1, "application/bsv-20", :OP_0, body, :OP_ENDIF]
  end

  defp mint(sym), do: envelope(~s({"p":"bsv-20","op":"deploy+mint","amt":"1000","sym":"#{sym}"}))

  # Stores a tx the way a raw block does: tx_json from the bytes, through the
  # chunk and tx steps. Returns the token row of output 0.
  defp ingest(bytes, height) do
    txid = RawBlock.txid(bytes)
    :ok = TxIngest.store(RawBlock.tx_json(txid, bytes), block_fixture(%{height: height}))
    Repo.get_by!(Instance, txid: txid, vout: 0)
  end

  defp ingest_real_mint do
    @real_mint_hex |> Base.decode16!(case: :lower) |> ingest(973_900)
  end

  defp ingest_script(chunks, height) do
    input = %BSV.TxIn{
      outpoint: %BSV.OutPoint{hash: :crypto.strong_rand_bytes(32), vout: 0},
      script: %BSV.Script{chunks: []},
      sequence: 0xFFFFFFFF
    }

    out = %BSV.TxOut{script: %BSV.Script{chunks: chunks}, satoshis: 1}
    tx = %BSV.Tx{version: 1, inputs: [input], outputs: [out], lock_time: 0}
    tx |> BSV.Tx.to_binary() |> ingest(height)
  end

  # A row as the code before #69 left it: no recipient, no lock, no stamp.
  defp as_stored_before(row) do
    parsed = Map.drop(row.parsed_data, ["recipient", "lock", "cosigner"])

    Repo.update_all(from(i in Instance, where: i.id == ^row.id),
      set: [parsed_data: parsed, recipient_version: nil]
    )

    Repo.get!(Instance, row.id)
  end

  setup do
    ProtocolRegistry.get_protocol_by_name("BSV20") || raise "BSV20 protocol not seeded"
    :ok
  end

  describe "the ingest path" do
    test "the real output, P2PKH before the envelope, names its recipient" do
      row = ingest_real_mint()

      assert row.txid == @real_mint_txid
      assert row.parsed_data["op"] == "mint"
      assert row.parsed_data["recipient"] == address(@real_mint_pkh)
      assert row.parsed_data["lock"] == "p2pkh"
      assert row.recipient_version == Steps.IndexTokens.version()
    end

    test "a P2PKH after the envelope still names its recipient" do
      row = ingest_script(mint("AFTER") ++ @p2pkh, 100)
      assert row.parsed_data["recipient"] == owner()
      assert row.parsed_data["lock"] == "p2pkh"
    end

    test "a cosign lock is held by its owner, and the cosigner is on the row" do
      row = ingest_script(mint("MNEE") ++ @cosign, 101)

      assert row.parsed_data["recipient"] == owner()
      assert row.parsed_data["lock"] == "cosign"
      assert row.parsed_data["cosigner"] == cosigner_hex()

      token = Tokens.get_token("#{row.txid}_0")
      assert token.recipient == owner()
      assert token.recipient_status == "known"
      assert token.cosigner == cosigner_hex()
      assert Tokens.balance_of("#{row.txid}_0", owner()) == 1000
    end

    test "any other lock names no recipient, and says so" do
      row = ingest_script(mint("LOCKED") ++ @other_lock, 102)

      refute Map.has_key?(row.parsed_data, "recipient")
      assert row.parsed_data["lock"] == "other"
      assert row.recipient_version == Steps.IndexTokens.version()

      token = Tokens.get_token("#{row.txid}_0")
      assert token.recipient == nil
      assert token.recipient_status == "unknown"
    end
  end

  describe "Inscription" do
    test "owner reads a lock on either side of the envelope" do
      assert {:ok, %{owner: before}} = Inscription.parse(%BSV.Script{chunks: @p2pkh ++ mint("A")})
      assert {:ok, %{owner: later}} = Inscription.parse(%BSV.Script{chunks: mint("A") ++ @p2pkh})
      assert before == owner() and later == owner()
    end

    test "lock_owner is for P2PKH only, and a bare P2PKH is one" do
      assert Inscription.lock_owner(%BSV.Script{chunks: @p2pkh}) == owner()
      assert Inscription.lock_owner(%BSV.Script{chunks: mint("A") ++ @cosign}) == nil
    end
  end

  describe "the re-index" do
    test "fills a nil recipient, and a rerun changes nothing" do
      row = ingest_real_mint() |> as_stored_before()

      dry = TokenRecipientsBackfill.run(973_000, 974_000)
      assert %{applied: false, outcome: "ok", rows_changed: 1, rows_below_version: 1} = dry
      assert dry.details.recipients_filled == 1
      assert Repo.get!(Instance, row.id).parsed_data["recipient"] == nil
      assert Repo.get!(Instance, row.id).recipient_version == nil

      first = TokenRecipientsBackfill.run(973_000, 974_000, apply: true)
      assert %{outcome: "ok", rows_examined: 1, rows_changed: 1, rows_below_version: 0} = first
      assert first.details.recipients_filled == 1

      filled = Repo.get!(Instance, row.id)
      assert filled.parsed_data["recipient"] == address(@real_mint_pkh)
      assert filled.parsed_data["lock"] == "p2pkh"
      assert filled.recipient_version == Steps.IndexTokens.version()

      again = TokenRecipientsBackfill.run(973_000, 974_000, apply: true)
      assert %{outcome: "ok", rows_examined: 0, rows_changed: 0, rows_below_version: 0} = again
      assert again.details.recipients_filled == 0
      assert Repo.get!(Instance, row.id) == filled

      assert [_, _, _] = Repo.all(from(r in Run, where: r.derivation == "token_recipients"))
    end

    test "a holder appears once its mint is filled" do
      row = ingest_script(mint("HOLD") ++ @cosign, 103) |> as_stored_before()
      assert Tokens.token_holders("#{row.txid}_0") == []

      TokenRecipientsBackfill.run(100, 110, apply: true)

      assert Tokens.balance_of("#{row.txid}_0", owner()) == 1000
      assert Repo.get!(Instance, row.id).parsed_data["cosigner"] == cosigner_hex()
    end

    test "stamps an unknown lock, so a rerun doesn't pick it again" do
      row = ingest_script(mint("OTHER") ++ @other_lock, 104) |> as_stored_before()

      first = TokenRecipientsBackfill.run(100, 110, apply: true)
      assert first.details.unknown_lock == 1
      assert first.rows_below_version == 0

      assert Repo.get!(Instance, row.id).parsed_data["lock"] == "other"
      assert %{rows_examined: 0} = TokenRecipientsBackfill.run(100, 110, apply: true)
    end

    test "keeps a recipient it can't read back" do
      row = ingest_script(mint("KEEP") ++ @other_lock, 105) |> as_stored_before()
      parsed = Map.put(row.parsed_data, "recipient", "1NamedByTheNode")
      Repo.update_all(from(i in Instance, where: i.id == ^row.id), set: [parsed_data: parsed])

      report = TokenRecipientsBackfill.run(100, 110, apply: true)

      assert report.details.recipients_filled == 0
      assert Repo.get!(Instance, row.id).parsed_data["recipient"] == "1NamedByTheNode"
    end

    test "a tx with no bytes stays below the version, and is counted" do
      row = ingest_script(mint("GONE") ++ @p2pkh, 106) |> as_stored_before()
      Repo.update_all(from(t in Transaction, where: t.txid == ^row.txid), set: [raw: ""])

      report = TokenRecipientsBackfill.run(100, 110, apply: true)

      assert report.details.no_raw == 1
      assert report.rows_changed == 0
      assert report.rows_below_version == 1
      assert Repo.get!(Instance, row.id).recipient_version == nil
    end

    test "leaves rows of other protocols alone" do
      row = ingest_script(mint("ONLY") ++ @p2pkh, 107) |> as_stored_before()
      other = ProtocolRegistry.get_protocol_by_name("Twetch")

      {:ok, untouched} =
        ProtocolRegistry.create_instance(%{
          protocol_id: other.id,
          txid: String.duplicate("ab", 32),
          vout: 0,
          block_height: 107,
          parsed_data: %{}
        })

      assert %{rows_examined: 1} = TokenRecipientsBackfill.run(100, 110, apply: true)
      assert Repo.get!(Instance, untouched.id).recipient_version == nil
      assert Repo.get!(Instance, row.id).recipient_version == Steps.IndexTokens.version()
    end

    test "Release runs it, a dry run by default" do
      row = ingest_script(mint("REL") ++ @p2pkh, 108) |> as_stored_before()

      capture_io(fn ->
        assert %{applied: false} = Release.backfill_token_recipients(100, 110)
      end)

      assert Repo.get!(Instance, row.id).recipient_version == nil

      capture_io(fn ->
        assert %{applied: true} = Release.backfill_token_recipients(100, 110, apply: true)
      end)

      assert Repo.get!(Instance, row.id).parsed_data["recipient"] == owner()
    end

    test "runs as a backfill chain" do
      row = ingest_script(mint("CHAIN") ++ @p2pkh, 109) |> as_stored_before()

      assert "token_recipients" in BackfillChains.derivations()
      {:ok, chain} = BackfillChains.start("token_recipients", 100, 110, apply: true, step: 20)

      assert :ok = perform_job(BackfillChainWorker, %{"chain_id" => chain.id, "from" => 100})

      assert Repo.get!(Instance, row.id).parsed_data["recipient"] == owner()
      assert %{chain: %{status: "done"}, rows_changed: 1} = BackfillChains.status(chain.id)
    end
  end
end
