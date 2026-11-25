defmodule Bitblocks.Workers.BsvPaymentWorkerTest do
  @moduledoc """
  Slice 4 of docs/BSV_402.md: an accepted BSV 402 payment followed through
  our own (stubbed) node and our own headers to confirmed and settled, back
  to accepted on a reorg, dropped, conflicted, and the deny list refusing
  the sender's next payment (`Bitblocks.Payments.Bsv402.Confirmation`, run by
  `Bitblocks.Workers.BsvPaymentWorker`).

  The headers are real mainnet headers 0, 1 and 2 (`Bitblocks.RealHeaders`),
  so `Confirmation.held/1` checks them as it does in prod.
  """
  # async: false: the RPC stubs are global.
  use Bitblocks.DataCase, async: false
  use Oban.Testing, repo: Bitblocks.Repo

  @moduletag :capture_log

  import Ecto.Query

  alias Bitblocks.Chain.{Block, Headers}
  alias Bitblocks.ChainFixtures
  alias Bitblocks.Interop.Bsv402Vectors
  alias Bitblocks.Payments.{Bsv402, BsvPayment}
  alias Bitblocks.Payments.Bsv402.Confirmation
  alias Bitblocks.RealHeaders
  alias Bitblocks.Repo
  alias Bitblocks.Workers.BsvPaymentWorker
  alias BitblocksWeb.RpcStub

  @txid String.duplicate("a1", 32)
  @prev String.duplicate("b2", 32)
  @t0 ~U[2026-11-25 12:00:00.000000Z]

  setup do
    RpcStub.setup()
    on_exit(&RpcStub.clear/0)

    for height <- [0, 1, 2], do: RealHeaders.insert(height)
    :ok
  end

  defp hash(height), do: RealHeaders.fields(height).hash

  # A one-input, one-output transaction spending @prev:0. Unsigned: our node
  # is stubbed, and only its inputs are read here.
  defp raw_tx do
    prev = @prev |> Base.decode16!(case: :lower) |> :binary.bin_to_list() |> Enum.reverse()
    script = <<0x76, 0xA9, 0x14, 0::160, 0x88, 0xAC>>

    <<1::little-32, 1, :binary.list_to_bin(prev)::binary, 0::little-32, 0, 0xFFFFFFFF::little-32,
      1, 100::little-64, byte_size(script), script::binary, 0::little-32>>
  end

  defp payment!(attrs \\ %{}) do
    sender = Map.get(attrs, :sender_key, "02" <> String.duplicate("cd", 32))

    Repo.insert!(
      struct(
        %BsvPayment{
          txid: @txid,
          vout: 0,
          satoshis: 100,
          sender_key: sender,
          derivation_prefix: "bm9uY2U=",
          derivation_suffix: "MA==",
          raw_tx: raw_tx(),
          request_hash: String.duplicate("0", 64),
          price_sats: 100,
          caller: sender,
          accepted_at: @t0
        },
        Map.delete(attrs, :sender_key)
      )
    )
  end

  defp reload(row), do: Repo.get!(BsvPayment, row.id)

  defp at(minutes), do: DateTime.add(@t0, minutes * 60, :second)

  defp run(minutes), do: Confirmation.run(now: at(minutes))

  defp in_mempool, do: RpcStub.stub_getrawtransaction(@txid, 1, %{"txid" => @txid})

  defp mined_in(hash),
    do:
      RpcStub.stub_getrawtransaction(@txid, 1, %{
        "txid" => @txid,
        "blockhash" => hash,
        "confirmations" => 1
      })

  defp unknown_to_node do
    not_found =
      {:error, %{"code" => -5, "message" => "No such mempool or blockchain transaction"}}

    RpcStub.stub_getrawtransaction(@txid, 1, not_found)

    RpcStub.stub_gettxoutproof(
      [@txid],
      nil,
      {:error, %{"code" => -5, "message" => "Transaction not yet in block"}}
    )
  end

  # Heights 3..`through` above the real headers, so our tip is `through`.
  defp blocks_through(through) do
    for height <- 3..through//1, do: ChainFixtures.block_fixture(%{height: height})
  end

  describe "accepted to settled" do
    test "waits while in the mempool, backing off" do
      row = payment!()
      in_mempool()

      assert %{checked: 1, moved: []} = run(0)
      row = reload(row)
      assert row.status == "accepted"
      assert row.checks == 1
      assert row.next_check_at == at(1)

      # Not due yet: nothing asked.
      assert %{checked: 0} = run(0)

      assert %{checked: 1} = run(1)
      assert reload(row).next_check_at == at(3)
    end

    test "confirmed in a block our headers hold, then settled six deep" do
      row = payment!()
      mined_in(hash(1))

      assert %{moved: [{@txid, "accepted", "confirmed"}]} = run(0)
      row = reload(row)
      assert row.status == "confirmed"
      assert row.block_hash == hash(1)
      assert row.block_height == 1
      assert row.confirmed_at == at(0)

      # Two deep: still confirmed, and no node call needed for it.
      RpcStub.clear()
      assert %{moved: []} = run(1)
      assert reload(row).status == "confirmed"
      assert RpcStub.calls() == []

      blocks_through(6)
      assert Confirmation.settle_depth() == 6
      assert %{moved: [{@txid, "confirmed", "settled"}]} = run(2)

      row = reload(row)
      assert row.status == "settled"
      assert row.closed_at == at(2)
      assert row.block_height == 1

      # Settled is final: never asked about again.
      assert %{checked: 0} = run(60)
    end

    test "a node without a tx index answers through its proof's header" do
      row = payment!()

      RpcStub.stub_getrawtransaction(
        @txid,
        1,
        {:error, %{"code" => -5, "message" => "No such mempool or blockchain transaction"}}
      )

      header = Headers.at(1).header
      RpcStub.stub_gettxoutproof([@txid], nil, header <> "0100000001" <> @txid <> "0101")

      run(0)
      row = reload(row)
      assert row.status == "confirmed"
      assert row.block_hash == hash(1)
    end

    test "a block our headers don't hold yet is waited for, not taken on trust" do
      row = payment!()
      mined_in(String.duplicate("00", 32))

      run(0)
      assert reload(row).status == "accepted"
    end

    test "our node not answering leaves the row for the next check" do
      row = payment!()

      run(0)
      row = reload(row)
      assert row.status == "accepted"
      assert row.checks == 1
      assert row.reason == nil
    end

    test "the worker runs it on the default lane, a no-op with nothing open" do
      assert :ok = perform_job(BsvPaymentWorker, %{})

      row = payment!(%{accepted_at: DateTime.utc_now()})
      mined_in(hash(1))

      assert :ok = perform_job(BsvPaymentWorker, %{})
      assert reload(row).status == "confirmed"
      assert BsvPaymentWorker.new(%{}).changes.priority == 5
    end
  end

  describe "a reorg" do
    test "a confirmed payment whose block is orphaned goes back to waiting, then is mined again" do
      row = payment!()
      mined_in(hash(1))
      run(0)
      assert reload(row).status == "confirmed"

      # Block 1 replaced at its height by another block: ours is orphaned.
      Repo.delete_all(from b in Block, where: b.height == 1)
      RealHeaders.insert(1, %{hash: String.duplicate("ef", 32)})
      in_mempool()

      assert %{moved: [{@txid, "confirmed", "accepted"}]} = run(1)
      row = reload(row)
      assert row.status == "accepted"
      assert row.block_hash == nil
      assert row.block_height == nil
      assert row.confirmed_at == nil
      assert row.reason =~ "left the best chain"

      # Mined again, in block 2.
      mined_in(hash(2))
      assert %{moved: [{@txid, "accepted", "confirmed"}]} = run(2)
      row = reload(row)
      assert row.block_height == 2
      assert row.block_hash == hash(2)
    end
  end

  describe "dropped" do
    test "unknown to our node: sent again once, then dropped after the deadline" do
      row = payment!()
      unknown_to_node()
      RpcStub.stub_gettxout(@prev, 0, %{"value" => 0.000002, "confirmations" => 10})
      RpcStub.stub_sendrawtransaction(@txid)

      run(0)
      row = reload(row)
      assert row.status == "accepted"
      assert row.rebroadcast_at == at(0)
      assert RpcStub.calls(:sendrawtransaction) == [[Base.encode16(raw_tx(), case: :lower)]]

      # Still unknown later: not sent a second time.
      run(30)
      assert length(RpcStub.calls(:sendrawtransaction)) == 1
      assert reload(row).status == "accepted"

      assert Confirmation.drop_after_hours() == 24
      assert %{moved: [{@txid, "accepted", "dropped"}]} = run(24 * 60)
      row = reload(row)
      assert row.status == "dropped"
      assert row.reason =~ "not in our node's mempool or in a block"
      assert row.closed_at == at(24 * 60)
      # Its rows are kept.
      assert row.raw_tx == raw_tx()
    end

    test "in the mempool but in no block by the deadline" do
      row = payment!()
      in_mempool()

      run(24 * 60)
      row = reload(row)
      assert row.status == "dropped"
      assert row.reason =~ "in our node's mempool"
    end
  end

  describe "conflicted" do
    test "unknown to our node, with an input spent by another" do
      row = payment!()
      unknown_to_node()
      RpcStub.stub_gettxout(@prev, 0, nil)

      assert %{moved: [{@txid, "accepted", "conflicted"}]} = run(0)
      row = reload(row)
      assert row.status == "conflicted"
      assert row.reason =~ "#{@prev}:0 is spent"
      assert RpcStub.calls(:sendrawtransaction) == []
    end
  end

  describe "the deny list" do
    @doc_map Jason.decode!(Bsv402Vectors.body())

    defp pays_exact do
      vector = Enum.find(@doc_map["vectors"], &(&1["id"] == "pays-exact"))

      held =
        Map.new(
          @doc_map["headers"],
          &{&1["height"],
           %{
             hash: "synthetic",
             merkleroot: &1["merkleroot"],
             num_tx: &1["tx_count"],
             verified: true,
             canonical: true
           }}
        )

      opts = [
        identity:
          Bsv402.identity_from(
            Base.decode16!(@doc_map["server"]["identity_private_key"], case: :lower)
          ),
        price: @doc_map["price_sats"],
        now_ms: @doc_map["now_ms"],
        max_beef_bytes: @doc_map["max_beef_bytes"],
        headers: fn heights -> Map.take(held, heights) end,
        tip: held |> Map.keys() |> Enum.max(),
        broadcast: fn _raw -> :accepted end
      ]

      request = vector["request"]

      {vector["payment"],
       %{method: request["method"], path: request["path"], query: request["query"]}, opts}
    end

    test "a sender whose payment conflicted is refused its next payment, for a period" do
      sender = @doc_map["sender"]["identity_key"]
      row = payment!(%{sender_key: sender})
      unknown_to_node()
      RpcStub.stub_gettxout(@prev, 0, nil)
      run(0)
      assert reload(row).status == "conflicted"

      {payment, request, opts} = pays_exact()

      assert {:error, %{reason: :denied, status: 402, detail: detail}} =
               Bsv402.verify(payment, request, opts)

      assert detail =~ "dropped or conflicted"
      # Nothing claimed for the refused payment.
      assert Repo.aggregate(BsvPayment, :count) == 1

      assert Confirmation.denied?(sender, at(0))
      assert Confirmation.denied_count(at(0)) == 1
      assert Confirmation.deny_hours() == 168
      refute Confirmation.denied?(sender, at(168 * 60 + 1))

      # Once the period is over, the same payment is taken.
      assert {:ok, %{outcome: :accepted}} =
               Bsv402.verify(payment, request, Keyword.put(opts, :denied?, fn _ -> false end))
    end

    test "a dropped payment denies its sender too; a settled one doesn't" do
      dropped =
        payment!(%{
          status: "dropped",
          closed_at: DateTime.utc_now(),
          sender_key: "02" <> String.duplicate("11", 32)
        })

      assert Confirmation.denied?(dropped.sender_key)

      settled =
        payment!(%{
          txid: String.duplicate("c3", 32),
          status: "settled",
          closed_at: DateTime.utc_now(),
          sender_key: "02" <> String.duplicate("22", 32)
        })

      refute Confirmation.denied?(settled.sender_key)
    end
  end

  describe "the status" do
    test "names the oldest open payment and the counts" do
      payment!()
      assert %{txid: @txid, status: "accepted"} = Confirmation.oldest_open()
      assert Bsv402.counts() == %{"accepted" => 1}
    end
  end
end
