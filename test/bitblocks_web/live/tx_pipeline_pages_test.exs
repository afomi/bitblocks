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

    {:ok, view, _html} = live(conn, ~p"/transactions/#{parent_txid}")
    assert view |> element("#tx-sats-in") |> render() =~ "—"
    assert render(view) =~ "We never guess them."
  end

  test "an inscription in a collection gets NFT and collection badges", %{conn: conn} do
    block = block_fixture(%{height: 31})
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

  test "the homepage's recent blocks show fees and reward, a dash until completed", %{conn: conn} do
    block_fixture(%{height: 50, sync_state: "completed", fees: 2_500, miner_reward: 625_002_500})
    block_fixture(%{height: 51, sync_state: "header_only"})

    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "fees 2,500 sats"
    assert html =~ "reward 6.250025 BSV"
    assert html =~ "fees —"
  end
end
