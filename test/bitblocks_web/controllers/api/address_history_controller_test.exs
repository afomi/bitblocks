defmodule BitblocksWeb.Api.AddressHistoryControllerTest do
  # WhatsOnChain answers from this process's dictionary (Bitblocks.WocStub)
  # and the cache is keyed by a fresh address per test, so tests stay apart.
  # Not async: every test stores the same heights (0..9) and spends the same
  # funding outpoint, so two at once deadlock in Postgres on those keys.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.{Block, RawBlock, TxIngest}
  alias Bitblocks.OrdinalFixtures
  alias Bitblocks.Repo

  setup do
    key = BSV.PrivKey.new() |> BSV.PubKey.from_privkey()
    address = key |> BSV.Address.from_pubkey() |> BSV.Address.to_string()
    %{address: address, pubkey: BSV.PubKey.to_binary(key)}
  end

  # Stores a real tx into the stored block at `height`, through the pipeline
  # (so its spends land in spend_index).
  defp store(outputs, height, inputs \\ [OrdinalFixtures.funding_outpoint()]) do
    {txid, hex} = OrdinalFixtures.tx(inputs, outputs)
    block = Repo.get_by!(Block, height: height)
    :ok = TxIngest.store(RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed)), block)
    txid
  end

  defp pay(address, sats), do: OrdinalFixtures.p2pkh(address, sats)
  defp elsewhere(sats), do: OrdinalFixtures.p2pkh(OrdinalFixtures.address(), sats)

  defp history(conn, address, query \\ "") do
    conn |> get("/api/v1/addresses/#{address}/history#{query}") |> json_response(200)
  end

  defp woc_history(address, entries) do
    Process.put(:woc_address_history, %{
      {address, nil} => %{
        history: Enum.map(entries, fn {txid, height} -> %{txid: txid, height: height} end),
        next_token: nil
      }
    })
  end

  test "a history wholly below complete_through is exact, from the index alone", %{
    conn: conn,
    address: address
  } do
    completed_chain_fixture(6)
    received = store([pay(address, 100_000), elsewhere(5)], 3)
    spent = store([elsewhere(60_000), pay(address, 30_000)], 5, ["#{received}_0"])
    _unrelated = store([elsewhere(7)], 4)

    body = history(conn, address)

    assert body["data"] == [
             %{
               "txid" => spent,
               "height" => 5,
               "net_sats" => -70_000,
               "net_sats_reason" => nil,
               "source" => "local"
             },
             %{
               "txid" => received,
               "height" => 3,
               "net_sats" => 100_000,
               "net_sats_reason" => nil,
               "source" => "local"
             }
           ]

    assert %{
             "status" => "exact",
             "indexed_through_height" => 6,
             "tip_height" => 6,
             "next_cursor" => nil,
             "sources" => [%{"source" => "index", "from_height" => 0, "through_height" => 6}]
           } = body["meta"]
  end

  describe "above complete_through" do
    setup %{address: address} do
      completed_chain_fixture(6)
      for h <- 7..9, do: block_fixture(%{height: h, sync_state: "header_only"})
      local = store([pay(address, 100_000)], 5)

      recent =
        OrdinalFixtures.tx([OrdinalFixtures.funding_outpoint()], [pay(address, 25_000)])
        |> OrdinalFixtures.publish(8)

      %{local: local, recent: recent}
    end

    test "rows above it come from WhatsOnChain, exact when it reaches our tip", %{
      conn: conn,
      address: address,
      local: local,
      recent: recent
    } do
      woc_history(address, [{local, 5}, {recent, 8}])
      Process.put(:woc_chain_tip, 9)

      body = history(conn, address)

      assert [
               %{
                 "txid" => ^recent,
                 "height" => 8,
                 "net_sats" => 25_000,
                 "source" => "whatsonchain"
               },
               %{"txid" => ^local, "height" => 5, "net_sats" => 100_000, "source" => "local"}
             ] = body["data"]

      assert %{
               "status" => "exact",
               "indexed_through_height" => 6,
               "tip_height" => 9,
               "sources" => [
                 %{"source" => "index", "from_height" => 0, "through_height" => 6},
                 %{
                   "source" => "whatsonchain",
                   "from_height" => 7,
                   "through_height" => 9,
                   "status" => "ok"
                 }
               ]
             } = body["meta"]
    end

    test "partial when WhatsOnChain is unavailable, with the index rows and the reason", %{
      conn: conn,
      address: address,
      local: local
    } do
      Process.put(:woc_address_history, %{{address, nil} => {:error, :timeout}})

      body = history(conn, address)

      assert [%{"txid" => ^local, "source" => "local"}] = body["data"]
      assert body["meta"]["status"] == "partial"

      assert %{
               "source" => "whatsonchain",
               "from_height" => 7,
               "status" => "unavailable",
               "reason" => "timeout"
             } = List.last(body["meta"]["sources"])
    end

    test "partial when WhatsOnChain answers but doesn't say how far", %{
      conn: conn,
      address: address,
      recent: recent
    } do
      woc_history(address, [{recent, 8}])
      assert history(conn, address)["meta"]["status"] == "partial"
    end

    test "net sats is nil with a reason when an input of the address has no known value", %{
      conn: conn,
      address: address,
      pubkey: pubkey
    } do
      # Spends an output of the address that neither we nor WoC's page hold:
      # the unlock names the address's key, so the input is the address's.
      [prev, vout] = String.split(OrdinalFixtures.funding_outpoint(), "_")

      input = %BSV.TxIn{
        outpoint: %BSV.OutPoint{
          hash: prev |> Base.decode16!(case: :lower) |> reverse(),
          vout: String.to_integer(vout)
        },
        script: %BSV.Script{chunks: [:binary.copy(<<0x30>>, 71), pubkey]}
      }

      tx = %BSV.Tx{inputs: [input], outputs: [elsewhere(1_000), pay(address, 500)]}

      txid =
        OrdinalFixtures.publish({BSV.Tx.get_txid(tx), BSV.Tx.to_binary(tx, encoding: :hex)}, 9)

      woc_history(address, [{txid, 9}])

      assert [
               %{
                 "txid" => ^txid,
                 "net_sats" => nil,
                 "net_sats_reason" => "input_value_unknown",
                 "source" => "whatsonchain"
               }
               | _
             ] = history(conn, address)["data"]
    end

    test "past its bound WhatsOnChain fails loudly, never a short list", %{
      conn: conn,
      address: address
    } do
      over = Bitblocks.Woc.AddressHistory.max_txs() + 1
      woc_history(address, for(i <- 1..over, do: {"t#{i}", 8}))

      body = history(conn, address)
      assert body["meta"]["status"] == "partial"
      assert Enum.all?(body["data"], &(&1["source"] == "local"))

      assert %{"status" => "unavailable", "reason" => "too_many_txs"} =
               List.last(body["meta"]["sources"])
    end
  end

  test "pages newest first by the <height>:<txid> cursor", %{conn: conn, address: address} do
    completed_chain_fixture(4)
    txids = for h <- [2, 4, 4], do: store([pay(address, 1_000)], h)

    expected =
      txids
      |> Enum.zip([2, 4, 4])
      |> Enum.sort_by(fn {txid, h} -> {h, txid} end, :desc)
      |> Enum.map(&elem(&1, 0))

    first = history(conn, address, "?limit=2")
    assert Enum.map(first["data"], & &1["txid"]) == Enum.take(expected, 2)
    assert first["meta"]["next_cursor"] == "4:#{Enum.at(expected, 1)}"

    second = history(build_conn(), address, "?limit=2&cursor=#{first["meta"]["next_cursor"]}")
    assert Enum.map(second["data"], & &1["txid"]) == [List.last(expected)]
    assert second["meta"]["next_cursor"] == nil
  end

  test "refuses a bad cursor, limit or address", %{conn: conn, address: address} do
    assert conn
           |> get("/api/v1/addresses/#{address}/history?cursor=42")
           |> json_response(400)
           |> Map.fetch!("error") =~ "Invalid cursor"

    assert build_conn()
           |> get("/api/v1/addresses/#{address}/history?limit=0")
           |> json_response(400)
           |> Map.fetch!("error") =~ "Invalid limit"

    assert build_conn()
           |> get("/api/v1/addresses/1BvBMSEYst0OIlInvalid/history")
           |> json_response(400)
           |> Map.fetch!("error") == "Invalid address"
  end

  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
end
