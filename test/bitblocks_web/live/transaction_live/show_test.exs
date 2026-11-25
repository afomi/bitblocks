defmodule BitblocksWeb.TransactionLive.ShowTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures, only: [tx: 2, p2pkh: 2, address: 0, funding_outpoint: 0]

  alias Bitblocks.Script.Templates

  # The genesis coinbase: one P2PK output paying 50 BSV to Satoshi's key.
  @genesis_txid "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
  @genesis_raw "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"
  @genesis_pubkey "04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f"

  describe "the value of each input" do
    # Input values come from the previous txs' stored outputs in one query,
    # never by loading and decoding each previous tx (a crawler on
    # many-input txs ran a node out of memory that way, 2026-11-18).
    defp store!(hex_tx, height) do
      {txid, hex} = hex_tx
      json = Bitblocks.Chain.RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))
      :ok = Bitblocks.Chain.TxIngest.store(json, block_fixture(%{height: height}))
      txid
    end

    test "each input reads its previous output's sats, in one lookup", %{conn: conn} do
      parent_a =
        store!(tx([funding_outpoint()], [p2pkh(address(), 1_234), p2pkh(address(), 5_678)]), 10)

      parent_b = store!(tx([funding_outpoint()], [p2pkh(address(), 9_000)]), 11)
      unstored = funding_outpoint()

      child =
        store!(
          tx(["#{parent_a}_1", "#{parent_b}_0", "#{parent_a}_0", unstored], [
            p2pkh(address(), 100)
          ]),
          12
        )

      ref = make_ref()
      parent = self()
      handler = "input-sats-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:bitblocks, :repo, :query],
        fn _, _, meta, _ ->
          send(parent, {ref, {meta.query, meta.params}})
        end,
        nil
      )

      {:ok, view, _html} = live(conn, ~p"/transactions/#{child}")
      :telemetry.detach(handler)

      queries = collect(ref, [])
      assert Enum.any?(queries, fn {sql, _} -> sql =~ "outputs[i.vout + 1]" end)

      # No query loads a previous tx's row with its raw bytes.
      refute Enum.any?(queries, fn {sql, params} ->
               sql =~ ~r/t0\."raw"/ and Enum.any?(params, &(&1 in [parent_a, parent_b]))
             end)

      assert view |> element("#input-source-0") |> render() =~ "5,678"
      assert view |> element("#input-source-1") |> render() =~ "9,000"
      assert view |> element("#input-source-2") |> render() =~ "1,234"
      assert view |> element("#input-source-3") |> render() =~ "—"
    end

    defp collect(ref, acc) do
      receive do
        {^ref, query} -> collect(ref, [query | acc])
      after
        0 -> acc
      end
    end
  end

  test "a Rexxie's banner states membership and ownership in sentences", %{conn: conn} do
    # Rexxie #1's mint, from the bundled catalog.
    mint = "52c8ee4935f983b7ce10b84882cb42b30d989a4385eaec1289fafe88325eb53f"
    insert_tx(@genesis_raw, mint)

    Bitblocks.Repo.insert!(%Bitblocks.OrdinalCollections.Item{
      collection_id: Bitblocks.OrdinalCollections.known()["rexxies"],
      origin: "#{mint}_3",
      mint_txid: mint,
      trace_state: "untraced"
    })

    {:ok, view, _html} = live(conn, ~p"/transactions/#{mint}")

    claims = view |> element("#collection-claims") |> render()
    assert claims =~ "Membership verified."
    assert claims =~ "Not traced yet."
  end

  # https://github.com/afomi/bitblocks/issues/101: a bare multisig output
  # (1-of-1, OP_1 <pubkey> OP_1 OP_CHECKMULTISIG) crashed the page, since the
  # type label had no clause for :multisig.
  test "a tx with a bare multisig output renders and labels it", %{conn: conn} do
    multisig = "51" <> "21" <> "02" <> String.duplicate("11", 32) <> "51" <> "ae"

    raw =
      String.replace(
        @genesis_raw,
        "434104" <> String.slice(@genesis_pubkey, 2..-1//1) <> "ac",
        "25" <> multisig
      )

    assert raw != @genesis_raw
    txid = String.duplicate("ab", 32)
    insert_tx(raw, txid)

    {:ok, _view, html} = live(conn, ~p"/transactions/#{txid}")
    assert html =~ "Multisig"
  end

  # The civil_registry multisig demo: two people open the funding and the
  # release txids and ask "who had to agree, and who did?" The lock is qart's
  # p2ms_2_of_3 vector (Bitblocks.MultisigFixtures); its keys are private
  # keys 1, 2 and 3.
  describe "who had to agree" do
    test "a funding tx reads as locked to 2 of these 3 keys, each with a copy button",
         %{conn: conn} do
      funding = store!(Bitblocks.MultisigFixtures.funding(), 20)
      [key1, key2, key3] = Bitblocks.MultisigFixtures.vector()["pubkeys"]

      {:ok, view, _html} = live(conn, ~p"/transactions/#{funding}")

      section = view |> element("#multisig-output-0") |> render()
      assert section =~ "Output #0 is locked to 2 of these 3 keys."
      assert section =~ "Any 2 of them, signing together, can spend it."
      assert section =~ "0279be66…16f81798"
      assert section =~ "02c6047f…5c709ee5"
      assert section =~ "02f9308a…bce036f9"
      refute section =~ "Signed"

      for {key, k} <- Enum.with_index([key1, key2, key3]) do
        assert view
               |> element("#multisig-output-0-keys-#{k}-copy")
               |> render() =~ ~s(&quot;text&quot;:&quot;#{key}&quot;)
      end

      # The output card names the keys in full; one copy button per key on
      # the page, under "Who had to agree".
      card = view |> element("#output-0-multisig") |> render()
      assert card =~ "Locked to 2 of these 3 keys."
      assert card =~ key1
      refute card =~ "Copy"

      # The button's name holds its visible text, and a live region beside it
      # announces "Copied".
      button = view |> element("#multisig-output-0-keys-0-copy") |> render()
      assert button =~ "Copy"
      assert button =~ "key 1"
      refute button =~ "aria-label"
      assert has_element?(view, ~s(#multisig-output-0-keys-0-copy-status[aria-live="polite"]))
    end

    # 5 checks for the first input, 4 for each next one: input 15 runs out
    # after its first signature (Bitblocks.MultisigTest has the arithmetic).
    test "signatures past the page's check budget read as not checked", %{conn: conn} do
      {funding, _hex} = funding_tx = Bitblocks.MultisigFixtures.funding(16)
      store!(funding_tx, 20)

      release =
        store!(
          Bitblocks.MultisigFixtures.release_many(
            funding,
            [[3, 1] | List.duplicate([1, 3], 15)]
          ),
          21
        )

      {:ok, view, _html} = live(conn, ~p"/transactions/#{release}")

      assert view |> element("#multisig-input-15-signed") |> render() =~
               "Key 1 signed. We checked 1 of 2 signatures."

      assert view |> element("#multisig-input-15-keys-0") |> render() =~ "Signed"
      assert view |> element("#multisig-input-15-keys-1") |> render() =~ "Not checked"
      assert view |> element("#multisig-input-15-keys-2") |> render() =~ "Not checked"
      refute view |> element("#multisig-input-15") |> render() =~ "Didn&#39;t sign"

      assert view |> element("#multisig-input-15-signature-1") |> render() =~
               "Signature 2 wasn&#39;t checked: we stop after 64 checks on one page."

      assert view |> element("#multisig-input-0-signature-1") |> render() =~
               "Signature 2 is from key 1, but out of order, so it doesn&#39;t count."
    end

    test "a release says key 1 and key 3 signed, and key 2 didn't", %{conn: conn} do
      {funding, _hex} = funding_tx = Bitblocks.MultisigFixtures.funding()
      store!(funding_tx, 20)
      release = store!(Bitblocks.MultisigFixtures.release(funding, [1, 3]), 21)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{release}")

      section = view |> element("#multisig-input-0") |> render()
      assert section =~ "which was locked to 2 of these 3 keys."

      assert view |> element("#multisig-input-0-signed") |> render() =~
               "Key 1 and key 3 signed."

      assert view |> element("#multisig-input-0-keys-0") |> render() =~ "Signed"
      assert view |> element("#multisig-input-0-keys-1") |> render() =~ "Didn&#39;t sign"
      assert view |> element("#multisig-input-0-keys-2") |> render() =~ "Signed"
      assert section =~ "We didn&#39;t run the rest of the script."
      refute section =~ "couldn"
    end

    test "a signature from a key not in the lock reads as couldn't match", %{conn: conn} do
      {funding, _hex} = funding_tx = Bitblocks.MultisigFixtures.funding()
      store!(funding_tx, 20)
      release = store!(Bitblocks.MultisigFixtures.release(funding, [4, 3]), 21)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{release}")

      assert view |> element("#multisig-input-0-signed") |> render() =~ "Key 3 signed."

      assert view |> element("#multisig-input-0-signature-0") |> render() =~
               "Signature 1 couldn&#39;t match any of the 3 keys."

      refute has_element?(view, "#multisig-input-0-signature-1")
    end

    test "a release whose previous output we don't store says so", %{conn: conn} do
      {funding, _hex} = Bitblocks.MultisigFixtures.funding()
      release = store!(Bitblocks.MultisigFixtures.release(funding, [1, 3]), 21)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{release}")

      section = view |> element("#multisig-input-0") |> render()
      assert section =~ "Input #0: previous output not in our index."
      assert section =~ "we can&#39;t say which keys signed."
      refute section =~ "Signed"
    end

    test "a tx with no multisig has no such section", %{conn: conn} do
      insert_tx(@genesis_raw, @genesis_txid)
      {:ok, view, _html} = live(conn, ~p"/transactions/#{@genesis_txid}")
      refute has_element?(view, "#tx-multisig")
    end
  end

  test "an output type the label doesn't know reads as a plain script" do
    assert BitblocksWeb.TransactionLive.Show.output_type_label(:some_future_type) == "Script"
  end

  defp insert_tx(raw, txid, block_attrs \\ %{}) do
    block = block_fixture(block_attrs)

    transaction_fixture(
      txid: txid,
      raw: raw,
      block_hash: block.hash,
      block_height: block.height
    )
  end

  # Serializes a minimal one-input, one-output transaction whose sole output
  # carries the given locking script.
  defp raw_hex_with_output(%BSV.Script{} = script, satoshis) do
    tx = %BSV.Tx{
      version: 1,
      inputs: [
        %BSV.TxIn{
          outpoint: %BSV.OutPoint{hash: :crypto.strong_rand_bytes(32), vout: 0},
          script: %BSV.Script{chunks: []},
          sequence: 0xFFFFFFFF
        }
      ],
      outputs: [%BSV.TxOut{satoshis: satoshis, script: script}],
      lock_time: 0
    }

    BSV.Tx.to_binary(tx, encoding: :hex)
  end

  describe "HodLocker (#75)" do
    @hodlocker_txs "test/support/data/hodlocker_txs.json"
                   |> File.read!()
                   |> Jason.decode!()
                   |> Map.fetch!("txs")
                   |> Map.new(&{&1["txid"], &1["raw"]})

    test "a like shows the sats locked, the owner, the unlock height and the post", %{conn: conn} do
      like = "7f496c643364501f7b1c3f1593fd827b6e2af7207b3ead3ec04bb5666c16a88b"
      post = "f76b5b61f8c2d643d10aad4dd7256090c986799293447080041a23145d253ed9"
      # The fixture's block is our tip, below the unlock height.
      insert_tx(Map.fetch!(@hodlocker_txs, like), like)
      tip = Bitblocks.ChainTiles.chain_tip()

      {:ok, view, _html} = live(conn, ~p"/transactions/#{like}")

      assert view |> element("#tx-hodlocker h2") |> render() =~ "HodLocker like"
      assert has_element?(view, ~s(#tx-hodlocker-backs a[href="/transactions/#{post}"]))

      lock = view |> element("#hodlocker-lock-0") |> render()
      assert lock =~ "2,100,000,000"
      assert lock =~ "13PnV1oUFYAeMUzzvoKFWX9FpjnMxyUpM9"
      assert lock =~ "858,404"
      assert lock =~ "#{BitblocksWeb.Sats.delimit(858_404 - tip)} blocks to go"
    end

    test "a post shows what every indexed lock backs it with (#76)", %{conn: conn} do
      post = "f76b5b61f8c2d643d10aad4dd7256090c986799293447080041a23145d253ed9"
      like = "7f496c643364501f7b1c3f1593fd827b6e2af7207b3ead3ec04bb5666c16a88b"

      for txid <- [post, like] do
        tx = insert_tx(Map.fetch!(@hodlocker_txs, txid), txid)
        Bitblocks.Timelocks.index(tx, Bitblocks.Chain.get_block(tx.block_hash))
      end

      {:ok, view, _html} = live(conn, ~p"/transactions/#{post}")

      totals = view |> element("#tx-hodlocker-totals") |> render()
      assert totals =~ "2,100,000,001"
      assert totals =~ "in 2 locks"
      assert totals =~ "1 of the transactions behind them are likes"
    end

    test "a post names who backs it, with each lock's sats and unlock height (#75)", %{
      conn: conn
    } do
      post = "f76b5b61f8c2d643d10aad4dd7256090c986799293447080041a23145d253ed9"
      like = "7f496c643364501f7b1c3f1593fd827b6e2af7207b3ead3ec04bb5666c16a88b"

      for txid <- [post, like] do
        tx = insert_tx(Map.fetch!(@hodlocker_txs, txid), txid)
        Bitblocks.Timelocks.index(tx, Bitblocks.Chain.get_block(tx.block_hash))
      end

      {:ok, view, _html} = live(conn, ~p"/transactions/#{post}")

      backer = view |> element("#hodlocker-backer-#{like}-0") |> render()
      assert backer =~ "13PnV1oUFYAeMUzzvoKFWX9FpjnMxyUpM9"
      assert backer =~ "2,100,000,000"
      assert backer =~ "858,404"
      assert has_element?(view, ~s(#hodlocker-backer-#{like}-0 a[href="/transactions/#{like}"]))

      # The post's own lock is listed as the post.
      assert view |> element("#hodlocker-backer-#{post}-0") |> render() =~ "This post"
    end

    test "a post says how far the time lock index reaches (#75)", %{conn: conn} do
      alias Bitblocks.SyncProgress

      post = "f76b5b61f8c2d643d10aad4dd7256090c986799293447080041a23145d253ed9"
      insert_tx(Map.fetch!(@hodlocker_txs, post), post)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{post}")

      assert view |> element("#tx-hodlocker-coverage") |> render() =~
               "does not yet cover the chain from its first block"

      Bitblocks.Repo.insert!(%Bitblocks.Derivations.Run{
        derivation: "timelocks",
        version: Bitblocks.Timelocks.version(),
        from_height: 0,
        to_height: 900_000,
        applied: true,
        outcome: "ok",
        started_at: DateTime.utc_now()
      })

      snapshot = SyncProgress.empty_snapshot()

      :ets.insert(
        SyncProgress,
        {:snapshot, put_in(snapshot.overview.complete_through, 840_000)}
      )

      on_exit(fn -> :ets.insert(SyncProgress, {:snapshot, SyncProgress.empty_snapshot()}) end)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{post}")

      coverage = view |> element("#tx-hodlocker-coverage") |> render()
      assert coverage =~ "Time locks indexed through block"
      assert coverage =~ "840,000"
    end

    test "each vector is real: its bytes hash to its txid" do
      for {txid, raw} <- @hodlocker_txs do
        hash = :crypto.hash(:sha256, :crypto.hash(:sha256, Base.decode16!(raw, case: :lower)))
        assert hash |> reverse_bytes() |> Base.encode16(case: :lower) == txid
      end
    end

    # Prod's index stops far below HodLocker's era (blocks 810,000 to 838,000),
    # so a post there must read as not indexed yet, never as zero sats.
    test "a post above the time lock index says it is not indexed yet (#75)", %{conn: conn} do
      post = "f76b5b61f8c2d643d10aad4dd7256090c986799293447080041a23145d253ed9"
      insert_tx(Map.fetch!(@hodlocker_txs, post), post, %{height: 833_405})
      index_through(400_000)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{post}")

      totals = view |> element("#tx-hodlocker-totals") |> render()
      assert totals =~ "Not indexed yet."
      refute totals =~ "sats, in"

      coverage = view |> element("#tx-hodlocker-coverage") |> render()
      assert coverage =~ "Time locks indexed through block"
      assert coverage =~ "400,000"
      assert coverage =~ "This transaction was mined at block"
      assert coverage =~ "833,405"
      assert coverage =~ "above the index,"
      assert coverage =~ "so the locks backing this post may not be counted yet."
    end

    test "a like above the index shows its own lock, and says the post's total isn't counted (#75)",
         %{conn: conn} do
      like = "7f496c643364501f7b1c3f1593fd827b6e2af7207b3ead3ec04bb5666c16a88b"
      insert_tx(Map.fetch!(@hodlocker_txs, like), like, %{height: 833_405})
      index_through(400_000)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{like}")

      lock = view |> element("#hodlocker-lock-0") |> render()
      assert lock =~ "2,100,000,000"
      assert lock =~ "13PnV1oUFYAeMUzzvoKFWX9FpjnMxyUpM9"
      assert lock =~ "858,404"
      assert lock =~ "24,999 blocks to go"

      assert view |> element("#tx-hodlocker-totals") |> render() =~ "Not indexed yet."

      coverage = view |> element("#tx-hodlocker-coverage") |> render()
      assert coverage =~ "833,405"

      assert coverage =~
               "so this like and the other locks backing the post may not be counted yet."
    end

    test "a post in no block we hold says so, rather than read as mined (#75)", %{conn: conn} do
      post = "f76b5b61f8c2d643d10aad4dd7256090c986799293447080041a23145d253ed9"

      heightless_transaction_fixture(%{
        txid: post,
        raw: Map.fetch!(@hodlocker_txs, post),
        block_hash: String.duplicate("ab", 32)
      })

      index_through(400_000)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{post}")

      totals = view |> element("#tx-hodlocker-totals") |> render()
      assert totals =~ "Not indexed yet."
      assert totals =~ "while this transaction is in no block we hold"
      refute totals =~ "mined in"

      coverage = view |> element("#tx-hodlocker-coverage") |> render()
      assert coverage =~ "This transaction is not in a block we hold,"
      assert coverage =~ "so the locks backing this post may not be counted yet."
      refute coverage =~ "was mined at block"
    end

    test "a post the index covers up to our tip says every lock we hold is counted (#75)", %{
      conn: conn
    } do
      post = "f76b5b61f8c2d643d10aad4dd7256090c986799293447080041a23145d253ed9"
      insert_tx(Map.fetch!(@hodlocker_txs, post), post, %{height: 833_405})
      index_through(840_000)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{post}")

      assert view |> element("#tx-hodlocker-totals") |> render() =~
               "No lock we have indexed backs this post."

      coverage = view |> element("#tx-hodlocker-coverage") |> render()
      assert coverage =~ "840,000"
      assert coverage =~ "the chain tip"
      assert coverage =~ "These counts hold every lock in the blocks we have."
    end

    test "lock_coverage/3 places the index against the tx's block and our tip" do
      alias BitblocksWeb.TransactionLive.Show
      assert Show.lock_coverage(nil, 833_405, 900_000) == :unknown
      assert Show.lock_coverage(400_000, 833_405, 900_000) == :below
      assert Show.lock_coverage(400_000, nil, 900_000) == :below
      assert Show.lock_coverage(850_000, 833_405, 900_000) == :partial
      assert Show.lock_coverage(900_000, 833_405, 900_000) == :complete
      assert Show.lock_coverage(850_000, 833_405, nil) == :partial
    end

    test "a post reads as not indexed yet until the index covers the chain from block 0", %{
      conn: conn
    } do
      post = "f76b5b61f8c2d643d10aad4dd7256090c986799293447080041a23145d253ed9"
      insert_tx(Map.fetch!(@hodlocker_txs, post), post)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{post}")

      totals = view |> element("#tx-hodlocker-totals") |> render()
      assert totals =~ "Not indexed yet."
      assert totals =~ "covers the chain from its first block"
    end

    test "a post the index covers, short of our tip, with no lock says none is indexed yet", %{
      conn: conn
    } do
      post = "f76b5b61f8c2d643d10aad4dd7256090c986799293447080041a23145d253ed9"
      insert_tx(Map.fetch!(@hodlocker_txs, post), post, %{height: 833_405})
      block_fixture(%{height: 900_000})
      index_through(850_000)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{post}")

      assert view |> element("#tx-hodlocker-totals") |> render() =~
               "No lock backing this post is indexed yet"

      assert view |> element("#tx-hodlocker-coverage") |> render() =~
               "A lock mined above it may not be counted yet"
    end

    test "lock_state/2 counts down to the unlock height" do
      alias BitblocksWeb.TransactionLive.Show
      assert Show.lock_state(100, 90) == {:locked, 10}
      assert Show.lock_state(100, 100) == :unlocked
      assert Show.lock_state(100, nil) == :unknown
    end
  end

  defp reverse_bytes(bin),
    do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  # The time lock index reaches `through`: an applied backfill run from block
  # 0, with the sync complete through the same height.
  defp index_through(through) do
    alias Bitblocks.SyncProgress

    Bitblocks.Repo.insert!(%Bitblocks.Derivations.Run{
      derivation: "timelocks",
      version: Bitblocks.Timelocks.version(),
      from_height: 0,
      to_height: through,
      applied: true,
      outcome: "ok",
      started_at: DateTime.utc_now()
    })

    snapshot = SyncProgress.empty_snapshot()
    :ets.insert(SyncProgress, {:snapshot, put_in(snapshot.overview.complete_through, through)})
    on_exit(fn -> :ets.insert(SyncProgress, {:snapshot, SyncProgress.empty_snapshot()}) end)
  end

  describe "nLockTime (#76)" do
    @tx_vectors "priv/data/tx_types/tx_vectors.json"
                |> File.read!()
                |> Jason.decode!()
                |> Map.fetch!("vectors")
                |> Map.new(&{&1["name"], &1})

    # The vector in the block it was mined in, at its real height and time.
    defp insert_mined(v) do
      block = block_fixture(height: v["height"], time: v["block_time"])

      transaction_fixture(
        txid: v["txid"],
        raw: v["raw"],
        block_hash: block.hash,
        block_height: block.height
      )
    end

    test "an anti-fee-sniping lock still shows, labelled as such", %{conn: conn} do
      v = @tx_vectors["tx_nlocktime_anti_fee_sniping"]
      insert_mined(v)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{v["txid"]}")

      assert view |> element("#tx-nlocktime-until") |> render() =~ "Locked until block"
      assert view |> element("#tx-nlocktime-until") |> render() =~ "399,988"
      assert view |> element("#tx-nlocktime-state") |> render() =~ "Reached"
      assert view |> element("#tx-nlocktime-anti-fee-sniping") |> render() =~ "Anti-fee-sniping"
    end

    test "a lock far below its block shows with no anti-fee-sniping label", %{conn: conn} do
      v = @tx_vectors["tx_nlocktime_typed"]
      insert_mined(v)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{v["txid"]}")

      assert view |> element("#tx-nlocktime-until") |> render() =~ "Locked until"
      refute has_element?(view, "#tx-nlocktime-anti-fee-sniping")
    end

    test "a lock time with every input final says the rules ignore it", %{conn: conn} do
      v = @tx_vectors["tx_nlocktime_ignored"]
      insert_tx(v["raw"], v["txid"])

      {:ok, view, _html} = live(conn, ~p"/transactions/#{v["txid"]}")

      assert view |> element("#tx-nlocktime-until") |> render() =~ "Lock time set to block"
      assert view |> element("#tx-nlocktime-state") |> render() =~ "ignore this lock time"
    end

    test "a tx with lock time 0 has no lock time section", %{conn: conn} do
      insert_tx(@genesis_raw, @genesis_txid)
      {:ok, view, _html} = live(conn, ~p"/transactions/#{@genesis_txid}")
      refute has_element?(view, "#tx-nlocktime")
    end
  end

  describe "STAS tokens (#78)" do
    test "a STAS output shows its token id, owner, amount and data", %{conn: conn} do
      # The real STAS output 0 of 0f9e2366…54a8 (chain_vectors.json's chain_stas),
      # in a tx of our own around it.
      stas =
        "priv/data/tx_types/chain_vectors.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("vectors")
        |> Enum.find(&(&1["name"] == "chain_stas"))

      script = BSV.Script.from_binary!(stas["script_hex"], encoding: :hex)
      txid = String.duplicate("5a", 32)
      insert_tx(raw_hex_with_output(script, 4_000), txid)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{txid}")

      row = view |> element("#tx-stas #stas-output-0") |> render()
      assert row =~ "12xBMnFKjatg1djQwFnCMyu1PN9uH4hUBJ"
      assert row =~ "4,000"
      assert row =~ "Not splittable"
      assert row =~ "STAS ·"
      assert row =~ "Token"
    end

    test "a tx with no STAS output has no STAS section", %{conn: conn} do
      insert_tx(@genesis_raw, @genesis_txid)
      {:ok, view, _html} = live(conn, ~p"/transactions/#{@genesis_txid}")
      refute has_element?(view, "#tx-stas")
    end
  end

  describe "what happened" do
    test "a coinbase leads with the miner's text", %{conn: conn} do
      @genesis_raw
      |> insert_tx(@genesis_txid)
      |> Ecto.Changeset.change(total_output_satoshis: 5_000_000_000)
      |> Bitblocks.Repo.update!()

      {:ok, view, html} = live(conn, ~p"/transactions/#{@genesis_txid}")

      assert view |> element("#tx-summary #tx-miner-text") |> render() =~
               "Chancellor on brink of second bailout for banks"

      assert view |> element("#tx-headline") |> render() =~ "paid its miner 50 BSV"
      refute html =~ "What is a Transaction?"
    end

    test "a payment leads with its inputs, outputs and total", %{conn: conn} do
      script = %BSV.Script{chunks: [:OP_ADD, :OP_EQUAL]}

      tx =
        insert_tx(
          raw_hex_with_output(script, 150_000),
          "pay#{System.unique_integer([:positive])}"
        )

      tx |> Ecto.Changeset.change(total_output_satoshis: 150_000) |> Bitblocks.Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert view |> element("#tx-headline") |> render() =~
               "Spends 1 input to create 1 output, paying 0.0015 BSV in total."

      assert has_element?(view, "#input-source-0 a[href^='/transactions/']")

      # Value reads in the order it flows: where it came from, then where it went.
      html = render(view)
      assert has_element?(view, "#tx-output-status")

      assert :binary.match(html, ~s(id="tx-input-sources")) <
               :binary.match(html, ~s(id="tx-output-status"))
    end

    test "script and hex sit in one toggle, open to start, after the summary", %{conn: conn} do
      script = %BSV.Script{chunks: [:OP_ADD, :OP_EQUAL]}
      raw = raw_hex_with_output(script, 1_000)
      tx = insert_tx(raw, "toggle#{System.unique_integer([:positive])}")

      {:ok, view, html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert view |> element("#tx-raw-details > summary") |> render() =~
               "Raw transaction"

      assert has_element?(view, "#tx-raw-details #tx-raw", raw)
      assert has_element?(view, "#tx-raw-details #tx-outputs", "OP_ADD OP_EQUAL")
      assert has_element?(view, "#tx-raw-details[open]")

      before_toggle = html |> String.split(~s(id="tx-raw-details")) |> hd()
      refute before_toggle =~ "OP_ADD"
      refute before_toggle =~ raw
    end

    test "a row with no raw hex says it is not downloaded yet", %{conn: conn} do
      tx = insert_tx("00", "noraw#{System.unique_integer([:positive])}")
      tx |> Ecto.Changeset.change(raw: nil) |> Bitblocks.Repo.update!()

      {:ok, view, html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert view |> element("#tx-not-downloaded") |> render() =~ "not downloaded yet"
      refute has_element?(view, "#tx-raw-details")
      refute html =~ "could not be decoded"
    end

    test "a row whose bytes live only in the store reads them from there", %{conn: conn} do
      tx = insert_tx(@genesis_raw, @genesis_txid)
      tx |> Ecto.Changeset.change(raw: nil) |> Bitblocks.Repo.update!()
      :ok = Bitblocks.TxStore.put(@genesis_txid, Base.decode16!(@genesis_raw, case: :lower))

      {:ok, view, html} = live(conn, ~p"/transactions/#{@genesis_txid}")

      assert has_element?(view, "#tx-raw", @genesis_raw)
      assert html =~ "Chancellor"
      refute html =~ "not downloaded yet"
    end

    test "a row whose hex will not decode says so", %{conn: conn} do
      tx = insert_tx("00ff", "badraw#{System.unique_integer([:positive])}")

      {:ok, view, html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert view |> element("#tx-undecodable") |> render() =~ "could not be decoded"
      assert has_element?(view, "#tx-raw", "00ff")
      refute html =~ "not downloaded yet"
    end

    test "protocols are named in the summary and link to their pages", %{conn: conn} do
      script = %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, "meta", "node", "parent"]}
      tx = insert_tx(raw_hex_with_output(script, 0), "proto#{System.unique_integer([:positive])}")

      tx
      |> Ecto.Changeset.change(protocols: ["Metanet", "OrderBook", "Bitcom"])
      |> Bitblocks.Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert has_element?(view, ~s(#tx-protocols a[href="/metanet?txid=#{tx.txid}"]), "Metanet")
      assert has_element?(view, ~s(#tx-protocols a[href="/order-book"]), "Order book")
      assert has_element?(view, "#tx-protocols a[href^='/bitcom']", "Bitcom")
    end

    test "a B:// tx links to its file", %{conn: conn} do
      script = %BSV.Script{
        chunks: [:OP_FALSE, :OP_RETURN, "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", "hi", "text/plain"]
      }

      tx = insert_tx(raw_hex_with_output(script, 0), "bfile#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert has_element?(view, ~s(#tx-b-file[href="/b/#{tx.txid}"]))
      assert has_element?(view, "#tx-summary", "text/plain")

      assert has_element?(
               view,
               "#tx-c-address",
               "c://" <> (:crypto.hash(:sha256, "hi") |> Base.encode16(case: :lower))
             )
    end

    test "the outputs table names who was paid", %{conn: conn} do
      hash = :binary.copy(<<7>>, 20)

      script = %BSV.Script{
        chunks: [:OP_DUP, :OP_HASH160, hash, :OP_EQUALVERIFY, :OP_CHECKSIG]
      }

      tx =
        insert_tx(raw_hex_with_output(script, 900), "payee#{System.unique_integer([:positive])}")

      address = %BSV.Address{pubkey_hash: hash} |> BSV.Address.to_string()

      {:ok, view, _html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert has_element?(view, "#output-status-0", address)
    end
  end

  describe "script cards" do
    test "renders the genesis coinbase with a P2PK card showing the pubkey", %{conn: conn} do
      insert_tx(@genesis_raw, @genesis_txid)

      {:ok, _view, html} = live(conn, ~p"/transactions/#{@genesis_txid}")

      assert html =~ "Output #0"
      assert html =~ "P2PK"
      assert html =~ "Public Key:"
      assert html =~ @genesis_pubkey
      # 50 BSV output value on the card
      assert html =~ "50.00000000 BSV"
      # no registered template for P2PK — no badge
      refute html =~ "Template:"
    end

    test "sets inputs left and outputs right on desktop", %{conn: conn} do
      insert_tx(@genesis_raw, @genesis_txid)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{@genesis_txid}")

      assert has_element?(view, "#tx-inputs-outputs.lg\\:grid-cols-2 > #tx-inputs", "Input #0")
      assert has_element?(view, "#tx-inputs-outputs.lg\\:grid-cols-2 > #tx-outputs", "Output #0")
    end

    test "shows no part of a large tx's hex, and offers it whole", %{conn: conn} do
      script = %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, :binary.copy(<<7>>, 3_000)]}
      raw = raw_hex_with_output(script, 0)
      tx = insert_tx(raw, "large#{System.unique_integer([:positive])}")

      {:ok, view, html} = live(conn, ~p"/transactions/#{tx.txid}")

      size = div(byte_size(raw), 2)
      assert {nil, ^size} = BitblocksWeb.TransactionLive.Show.raw_shown(raw)
      refute html =~ binary_part(raw, 0, 200)
      assert has_element?(view, "#tx-raw-size", BitblocksWeb.Sats.delimit(size))

      assert has_element?(
               view,
               ~s(#tx-raw-download[href="/api/v1/txs/#{tx.txid}/raw"][download="#{tx.txid}.bin"])
             )

      assert has_element?(
               view,
               ~s(#tx-raw-download-hex[href="/api/v1/txs/#{tx.txid}/raw?format=hex"][download="#{tx.txid}.hex"])
             )
    end

    test "the bytes and downloads sit at the top of the page", %{conn: conn} do
      insert_tx(@genesis_raw, @genesis_txid)

      {:ok, view, html} = live(conn, ~p"/transactions/#{@genesis_txid}")

      assert has_element?(view, "#tx-raw-bytes", "204 bytes")
      [above_summary | _] = String.split(html, ~s(id="tx-summary"))
      assert above_summary =~ ~s(id="tx-raw-download-hex")
      assert above_summary =~ ~s(id="tx-raw-download")
    end

    test "shows a small tx's raw hex whole", %{conn: conn} do
      insert_tx(@genesis_raw, @genesis_txid)

      {:ok, view, html} = live(conn, ~p"/transactions/#{@genesis_txid}")

      assert html =~ @genesis_raw
      refute has_element?(view, "#tx-raw-size")
    end

    test "the raw route answers bytes, or the same bytes as hex", %{conn: conn} do
      insert_tx(@genesis_raw, @genesis_txid)

      bytes = get(conn, "/api/v1/txs/#{@genesis_txid}/raw")
      assert Base.encode16(bytes.resp_body, case: :lower) == @genesis_raw
      assert ["application/octet-stream"] = get_resp_header(bytes, "content-type")

      hex = get(conn, "/api/v1/txs/#{@genesis_txid}/raw?format=hex")
      assert hex.status == 200
      assert hex.resp_body == @genesis_raw
      assert ["text/plain"] = get_resp_header(hex, "content-type")
    end

    test "binary moves to the CDN once it serves /tx, and hex stays here", %{conn: conn} do
      insert_tx(@genesis_raw, @genesis_txid)
      System.put_env("TX_CDN_BASE_URL", "https://cdn.example.test/")
      on_exit(fn -> System.delete_env("TX_CDN_BASE_URL") end)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{@genesis_txid}")

      assert has_element?(
               view,
               ~s(#tx-raw-download[href="https://cdn.example.test/tx/#{@genesis_txid}"])
             )

      assert has_element?(
               view,
               ~s(#tx-raw-download-hex[href="/api/v1/txs/#{@genesis_txid}/raw?format=hex"])
             )
    end

    test "renders an unknown-script output with its full ASM without crashing", %{conn: conn} do
      script = %BSV.Script{chunks: [:OP_ADD, :OP_EQUAL]}
      raw = raw_hex_with_output(script, 1_000)
      tx = insert_tx(raw, "unknown#{System.unique_integer([:positive])}")

      {:ok, _view, html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert html =~ "Output #0"
      assert html =~ "Locking Script (ASM):"
      assert html =~ "OP_ADD OP_EQUAL"
      refute html =~ "Template:"
    end

    test "shows a template badge when a registered template matches the script", %{conn: conn} do
      digest = :crypto.hash(:sha256, "puzzle")
      script = %BSV.Script{chunks: [:OP_SHA256, digest, :OP_EQUAL]}

      {:ok, _template} =
        Templates.register(%{
          name: "Hash Puzzle",
          template_hash: Bitblocks.Script.template_hash(script)
        })

      raw = raw_hex_with_output(script, 546)
      tx = insert_tx(raw, "templated#{System.unique_integer([:positive])}")

      {:ok, _view, html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert html =~ "Template: Hash Puzzle"
      assert html =~ "OP_SHA256"
    end

    test "renders an OP_RETURN output as a minimal chunk-count card", %{conn: conn} do
      script = %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, "hello", "world"]}
      raw = raw_hex_with_output(script, 0)
      tx = insert_tx(raw, "opreturn#{System.unique_integer([:positive])}")

      {:ok, _view, html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert html =~ "OP_RETURN (2 chunks)"
      # the deep-dive section below the cards still renders the chunk data
      assert html =~ "OP_RETURN Data (1)"
      assert html =~ "hello"
    end

    test "badges an OP_RETURN card with its detected protocol handler", %{conn: conn} do
      script = %BSV.Script{
        chunks: [:OP_FALSE, :OP_RETURN, "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", "SET", "app", "x"]
      }

      raw = raw_hex_with_output(script, 0)
      tx = insert_tx(raw, "opreturnmap#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert has_element?(view, "span.bg-blue-100", "MAP")
    end
  end
end
