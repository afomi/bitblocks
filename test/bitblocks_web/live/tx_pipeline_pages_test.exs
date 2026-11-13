defmodule BitblocksWeb.TxPipelinePagesTest do
  # What the tx pipeline shows (docs/TX_PIPELINE.md): tallies, output status
  # and NFT badges on the tx page; fees and miner reward on the block page and
  # the homepage's recent blocks, with a dash until the block is completed.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures

  alias Bitblocks.Chain.{RawBlock, TxIngest}

  defp tx_json({txid, hex}), do: RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))

  test "the tx page shows sats in, out, fee, burned and each output's status", %{conn: conn} do
    block = block_fixture(%{height: 30})
    {parent_txid, _} = parent = tx([funding_outpoint()], [p2pkh(address(), 1_234_567)])

    burn = %BSV.TxOut{satoshis: 1_000, script: %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, "x"]}}
    {txid, _} = t = tx(["#{parent_txid}_0"], [p2pkh(address(), 1_200_000), burn])
    {spender, _} = s = tx(["#{txid}_0"], [p2pkh(address(), 1_100_000)])
    TxIngest.store_chunk([tx_json(parent), tx_json(t), tx_json(s)], block)

    {:ok, view, _html} = live(conn, ~p"/transactions/#{txid}")

    assert view |> element("#tx-sats-in") |> render() =~ "1,234,567 sats"
    assert view |> element("#tx-sats-out") |> render() =~ "1,201,000 sats"
    assert view |> element("#tx-fee") |> render() =~ "33,567 sats"
    assert view |> element("#tx-burned") |> render() =~ "1,000 sats"

    assert view |> element("#output-status-0") |> render() =~ "Spent by"
    assert has_element?(view, "#output-status-0 a[href='/transactions/#{spender}']")
    assert view |> element("#output-status-1") |> render() =~ "Unspendable"

    # Block 30 isn't completed, so an output with no recorded spend is unknown.
    {:ok, view, _html} = live(conn, ~p"/transactions/#{spender}")
    assert view |> element("#output-status-0") |> render() =~ "Unknown"
    refute has_element?(view, "#badge-utxo")

    {:ok, view, _html} = live(conn, ~p"/transactions/#{parent_txid}")
    assert view |> element("#tx-sats-in") |> render() =~ "—"
    assert render(view) =~ "We never guess them."
  end

  test "an inscription in a collection gets NFT and collection badges", %{conn: conn} do
    # Unspent is exact only when every block through the tip is synced.
    completed_chain_fixture(31)
    block = Bitblocks.Repo.get_by!(Bitblocks.Chain.Block, height: 31)
    collection_id = Bitblocks.OrdinalCollections.known()["grand-tardinians"]
    {txid, _} = t = tx([funding_outpoint()], [item(collection_id, "Tardinian 9", address())])
    assert :ok = TxIngest.store(tx_json(t), block)

    Bitblocks.Repo.insert!(%Bitblocks.OrdinalCollections.Item{
      collection_id: collection_id,
      origin: "#{txid}_0",
      mint_txid: txid,
      current_outpoint: "#{txid}_0",
      name: "Tardinian 9"
    })

    {:ok, view, _html} = live(conn, ~p"/transactions/#{txid}")

    assert has_element?(view, "#badge-inscription[href='/types/1sat-inscription']")

    assert view
           |> element("#badge-collection-grand-tardinians[href='/collections/grand-tardinians']")
           |> render() =~ "Grand Tardinians"

    assert has_element?(view, "#badge-utxo")
    refute has_element?(view, "#badge-run")
  end

  test "a Rare Candy mint links to the collection its lock names (#77)", %{conn: conn} do
    block = block_fixture(%{height: 33})
    txid = "0ef416e3b3f280b357e8a16e2f16cdda35f749cb8545ee031a21e39c030e9a7f"
    hex = File.read!("test/fixtures/collections/#{txid}.hex") |> String.trim()
    assert :ok = TxIngest.store(tx_json({txid, hex}), block)

    {:ok, view, _html} = live(conn, ~p"/transactions/#{txid}")

    assert view
           |> element("#badge-rare-candy[href='/collections/planetary-skies']")
           |> render() =~ "NFT: Rare Candy"

    refute has_element?(view, "#badge-run")
  end

  test "a Run tx links to the Run type", %{conn: conn} do
    block = block_fixture(%{height: 32})
    {txid, _} = t = tx([funding_outpoint()], [run_payload(%{}), p2pkh(address(), 1)])
    assert :ok = TxIngest.store(tx_json(t), block)

    {:ok, view, _html} = live(conn, ~p"/transactions/#{txid}")
    assert has_element?(view, "#badge-run[href='/types/run']")
  end

  test "the block page shows fees and miner reward once completed", %{conn: conn} do
    block_fixture(%{
      height: 40,
      sync_state: "completed",
      fees: 12_345,
      miner_reward: 5_000_012_345,
      subsidy: 5_000_000_000,
      fees_verified: true
    })

    block_fixture(%{height: 41, sync_state: "txs_syncing", fees: 1, miner_reward: 2})

    {:ok, view, _html} = live(conn, ~p"/blocks/40")
    assert view |> element("#block-fees") |> render() =~ "12,345 sats"
    reward = view |> element("#block-miner-reward") |> render()
    assert reward =~ "5,000,012,345 sats"
    assert reward =~ "5,000,000,000 sats plus fees."

    {:ok, view, _html} = live(conn, ~p"/blocks/41")
    assert view |> element("#block-fees") |> render() =~ "—"
    assert view |> element("#block-miner-reward") |> render() =~ "—"
  end

  test "the homepage's recent blocks show fees and reward once completed, and nothing before",
       %{conn: conn} do
    block_fixture(%{height: 50, sync_state: "completed", fees: 2_500, miner_reward: 625_002_500})
    block_fixture(%{height: 51, sync_state: "header_only"})

    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "fees 2,500 sats"
    assert html =~ "reward 6.250025 BSV"
    refute html =~ "fees —"
    assert Regex.scan(~r/fees /, html) |> length() == 1
  end

  describe "provenance (docs/DERIVED_DATA.md)" do
    require Ecto.Query
    alias Bitblocks.Chain.{Transaction, TxPipeline}

    test "the tx page names the versions that computed its tallies and analysis, and when",
         %{conn: conn} do
      block = block_fixture(%{height: 33})
      {txid, _} = t = tx([funding_outpoint()], [p2pkh(address(), 5_000)])
      assert :ok = TxIngest.store(tx_json(t), block)

      {:ok, view, _html} = live(conn, ~p"/transactions/#{txid}")
      provenance = view |> element("#tx-provenance") |> render()
      today = Date.utc_today() |> Date.to_iso8601()

      assert provenance =~ "Tallies v#{TxPipeline.version(:tallies)} · computed #{today}"
      assert provenance =~ "Script analysis v#{TxPipeline.version(:script_analysis)}"

      Bitblocks.Repo.update_all(
        Ecto.Query.from(t in Transaction, where: t.txid == ^txid),
        set: [tallies_version: nil]
      )

      {:ok, view, _html} = live(conn, ~p"/transactions/#{txid}")
      assert view |> element("#tx-provenance") |> render() =~ "Tallies: no version yet"
    end

    test "the block page names the version of its totals once completed", %{conn: conn} do
      block_fixture(%{height: 42, sync_state: "completed", fees: 0, miner_reward: 1})
      block_fixture(%{height: 43, sync_state: "completed", fees: 0, miner_reward: 1})
      block_fixture(%{height: 44, sync_state: "txs_syncing"})

      Bitblocks.Repo.update_all(
        Ecto.Query.from(b in Bitblocks.Chain.Block, where: b.height == 42),
        set: [tallies_version: TxPipeline.version(:block_totals)]
      )

      {:ok, view, _html} = live(conn, ~p"/blocks/42")

      assert view |> element("#block-provenance") |> render() =~
               "Totals v#{TxPipeline.version(:block_totals)}"

      {:ok, view, _html} = live(conn, ~p"/blocks/43")
      assert view |> element("#block-provenance") |> render() =~ "Totals: no version yet"

      {:ok, view, _html} = live(conn, ~p"/blocks/44")
      refute has_element?(view, "#block-provenance")
    end
  end
end
