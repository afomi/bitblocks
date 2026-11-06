defmodule Bitblocks.Bitcom.DiscoveryTest do
  # #24: commands in blocks the sync hasn't reached, found from address history.
  use Bitblocks.DataCase, async: true
  use Oban.Testing, repo: Bitblocks.Repo

  import Bitblocks.BitcomFixtures
  import Bitblocks.OrdinalFixtures, only: [publish: 2]

  alias Bitblocks.Bitcom
  alias Bitblocks.Bitcom.{Command, Discovery}
  alias Bitblocks.Chain.Transaction
  alias Bitblocks.{ProtocolRegistry, TxStore}
  alias Bitblocks.Workers.BitcomDiscoveryWorker

  setup do
    admin = BSV.PrivKey.new()
    %{admin: admin, address: address(admin)}
  end

  defp txid(raw), do: raw |> Base.decode16!(case: :lower) |> TxStore.txid()

  defp on_chain(raw, height) do
    id = txid(raw)
    publish({id, raw}, height)
    %{txid: id, height: height}
  end

  defp history(address, pages) do
    Process.put(
      :woc_address_history,
      Map.new(pages, fn {token, page} -> {{address, token}, page} end)
    )
  end

  test "a dry run counts what it finds and writes nothing", %{admin: admin, address: address} do
    raw = bitcom_raw_tx(admin, [["$", "useradd", address]])
    history(address, %{nil => %{history: [on_chain(raw, 600_000)], next_token: nil}})

    assert {:ok, %{history: 1, fetched: 1, commands: 1, logged: 0}} = Discovery.scan_page(address)
    assert Repo.aggregate(Command, :count) == 0
  end

  test "apply logs the command at its height, adds no tx row, and proves the owner", %{
    admin: admin,
    address: address
  } do
    {:ok, protocol} =
      ProtocolRegistry.create_protocol(%{
        address: address,
        name: "Discovered",
        category: :data_storage,
        verification_status: :unverified
      })

    raw = bitcom_raw_tx(admin, [["$", "useradd", address]], 3)
    %{txid: id} = entry = on_chain(raw, 600_000)
    history(address, %{nil => %{history: [entry], next_token: nil}})

    assert {:ok, %{logged: 1, proofs: 1}} = Discovery.scan_page(address, nil, apply: true)

    assert [%{txid: ^id, block_height: 600_000, valid: true, actor: ^address}] =
             Repo.all(Command)

    refute Repo.get_by(Transaction, txid: id)
    assert Repo.reload!(protocol).ownership_proof_txid == id
    assert [%{name: "Discovered"}] = Enum.filter(Bitcom.directory(), &(&1.address == address))
  end

  test "a tx that isn't a Bitcom command is fetched and ignored", %{
    admin: admin,
    address: address
  } do
    raw = bitcom_raw_tx(admin, [["19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", "data"]])
    history(address, %{nil => %{history: [on_chain(raw, 600_001)], next_token: nil}})

    assert {:ok, %{fetched: 1, commands: 0, logged: 0}} =
             Discovery.scan_page(address, nil, apply: true)
  end

  test "a second scan fetches nothing it has logged", %{admin: admin, address: address} do
    raw = bitcom_raw_tx(admin, [["$", "echo", "hi", "to", "readme"]])
    history(address, %{nil => %{history: [on_chain(raw, 600_002)], next_token: nil}})

    assert {:ok, %{fetched: 1}} = Discovery.scan_page(address, nil, apply: true)
    assert {:ok, %{history: 1, fetched: 0}} = Discovery.scan_page(address, nil, apply: true)
  end

  test "bytes that don't hash to the txid asked for are dropped", %{
    admin: admin,
    address: address
  } do
    raw = bitcom_raw_tx(admin, [["$", "useradd", address]])
    other = bitcom_raw_tx(admin, [["$", "useradd", address]], 4)
    id = txid(raw)
    publish({id, other}, 600_003)
    history(address, %{nil => %{history: [%{txid: id, height: 600_003}], next_token: nil}})

    assert {:ok, %{fetched: 0, logged: 0}} = Discovery.scan_page(address, nil, apply: true)
  end

  test "a failed lookup is an error, for the job to retry", %{address: address} do
    history(address, %{nil => {:error, :rate_limited}})

    assert {:error, :rate_limited} = Discovery.scan_page(address)
  end

  describe "the worker" do
    test "queues the next page while pages remain", %{address: address} do
      history(address, %{nil => %{history: [], next_token: "t2"}})

      assert :ok = perform_job(BitcomDiscoveryWorker, %{address: address, pages_left: 2})

      assert_enqueued(
        worker: BitcomDiscoveryWorker,
        args: %{address: address, token: "t2", pages_left: 1}
      )
    end

    test "stops at its page bound, and at the end of the history", %{address: address} do
      history(address, %{nil => %{history: [], next_token: "t2"}})

      assert :ok = perform_job(BitcomDiscoveryWorker, %{address: address, pages_left: 1})
      refute_enqueued(worker: BitcomDiscoveryWorker)
    end
  end
end
