defmodule BitblocksWeb.TxGraphLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Bitblocks.Repo
  alias Bitblocks.Chain.{Block, Transaction}

  setup do
    block_hash = String.duplicate("a", 64)

    %Block{}
    |> Block.changeset(%{
      hash: block_hash,
      height: 100,
      time: 1_231_006_505,
      num_tx: 3,
      tx: ["tx_a", "tx_b", "tx_c"],
      size: 500,
      version: 1,
      merkleroot: String.duplicate("b", 64),
      bits: "1d00ffff",
      nonce: 1,
      difficulty: "1.0",
      sync_state: "completed"
    })
    |> Repo.insert!()

    # Coinbase tx (no inputs referencing other txids)
    %Transaction{}
    |> Transaction.changeset(%{
      txid: "tx_a",
      raw: "01000000",
      version: "1",
      block_hash: block_hash,
      block_height: 100,
      inputs: [~s({"coinbase":"04ffff001d"})],
      outputs: [~s({"value":50,"address":"1A1zP1"})],
      input_count: 0,
      output_count: 1,
      total_output_satoshis: 5_000_000_000
    })
    |> Repo.insert!()

    # tx_b spends tx_a
    %Transaction{}
    |> Transaction.changeset(%{
      txid: "tx_b",
      raw: "01000000",
      version: "1",
      block_hash: block_hash,
      block_height: 100,
      inputs: [~s({"txid":"tx_a","vout":0})],
      input_txids: ["tx_a"],
      outputs: [~s({"value":49,"address":"1B2xyz"})],
      input_count: 1,
      output_count: 1,
      total_output_satoshis: 4_900_000_000
    })
    |> Repo.insert!()

    # tx_c spends tx_b
    %Transaction{}
    |> Transaction.changeset(%{
      txid: "tx_c",
      raw: "01000000",
      version: "1",
      block_hash: block_hash,
      block_height: 100,
      inputs: [~s({"txid":"tx_b","vout":0})],
      input_txids: ["tx_b"],
      outputs: [~s({"value":48,"address":"1C3abc"})],
      input_count: 1,
      output_count: 1,
      total_output_satoshis: 4_800_000_000
    })
    |> Repo.insert!()

    %{block_hash: block_hash}
  end

  test "renders tx graph page with search form", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/tx-graph")

    assert html =~ "Transaction Call Graph"
    assert html =~ "Enter a txid"
  end

  test "traces a transaction chain forward and backward", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tx-graph?txid=tx_b")

    # Wait for async load
    rendered = render(view)

    # Should show tx_b as root
    assert rendered =~ "tx_b"
    assert rendered =~ "(root)"

    # Should find tx_a (parent) and tx_c (child)
    assert rendered =~ "tx_a"
    assert rendered =~ "tx_c"
  end

  test "shows error for unknown txid", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tx-graph?txid=nonexistent_tx")

    rendered = render(view)
    assert rendered =~ "not found"
  end

  test "submit form traces a new txid", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tx-graph")

    view
    |> form("form", %{"txid" => "tx_a"})
    |> render_submit()

    rendered = render(view)
    assert rendered =~ "tx_a"
    assert rendered =~ "coinbase"
  end
end
