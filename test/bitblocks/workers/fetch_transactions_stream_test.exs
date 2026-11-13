defmodule Bitblocks.Workers.FetchTransactionsStreamTest do
  @moduledoc """
  The sync's block job on a block over the raw-block cap (#66): read from
  REST as a stream (`Chain.BlockStream`), stored chunk by chunk through the
  tx pipeline, resumed across bounded runs, and completed only by a run
  whose merkleroot verified with every tx stored.

  The cap is lowered to 100 KB so a synthetic block of a few hundred KB
  (`Bitblocks.SyntheticBlock`, the BlockStream tests' blocks) stands in for
  one of hundreds of MB.
  """
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.{Chain, SyntheticBlock}
  alias Bitblocks.Workers.FetchTransactionsWorker
  alias BitblocksWeb.RpcStub

  @cap 100_000

  setup do
    RpcStub.setup()
    RpcStub.clear()

    keys = [
      :raw_block_max_bytes,
      :tx_fetch_run_ms,
      :block_stream_max_tx_bytes,
      :block_stream_max_block_bytes,
      :sync_block_stream
    ]

    saved = for key <- keys, do: {key, Application.fetch_env(:bitblocks, key)}
    Application.put_env(:bitblocks, :raw_block_max_bytes, @cap)

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:bitblocks, key, v)
          :error -> Application.delete_env(:bitblocks, key)
        end
      end
    end)

    # About 200 txs, three of them 70 KB: several chunks of 100.
    big = SyntheticBlock.build(300_000)
    %{big: big}
  end

  defp header(big, attrs \\ %{}) do
    block_fixture(
      Map.merge(
        %{
          height: 0,
          hash: big.hash,
          merkleroot: big.merkleroot,
          num_tx: length(big.txids),
          size: nil,
          tx: [],
          sync_state: "header_only"
        },
        attrs
      )
    )
  end

  defp stored, do: Repo.aggregate(Chain.Transaction, :count)

  defp no_per_tx_calls! do
    assert RpcStub.calls(:getrawtransaction) == []
    assert RpcStub.calls(:batch_getrawtransaction) == []
    assert RpcStub.calls(:getblock) == []
  end

  defp perform(job), do: FetchTransactionsWorker.perform(Repo.reload!(job))

  # A byte inside the first 70 KB OP_RETURN, changed: the header still
  # hashes to the block's hash and every tx still parses, but one txid
  # differs, so the merkleroot can't rebuild.
  defp tamper(bytes) do
    {at, _} = :binary.match(bytes, :binary.copy(<<0x42>>, 1_000))
    <<head::binary-size(at + 500), _byte, tail::binary>> = bytes
    <<head::binary, 0x43, tail::binary>>
  end

  test "a block REST reports over the cap streams end to end, every tx through the pipeline",
       %{big: big} do
    assert length(big.txids) > 150
    block = header(big)
    RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

    assert :ok = FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

    completed = Chain.get_block!(0)
    assert completed.sync_state == "completed"
    assert completed.size == byte_size(big.bytes)
    assert stored() == length(big.txids)

    # Through the pipeline: the chunk steps stamp every row. (Script analysis
    # leaves its columns empty here: synthetic unlocking scripts are random
    # bytes the analyzer doesn't decode, as on any path.)
    for txid <- big.txids do
      tx = Chain.get_transaction!(txid)
      assert tx.block_hash == big.hash
      assert tx.size_bytes > 0
      assert is_integer(tx.tallies_version)
      assert is_integer(tx.tx_types_version)
    end

    # The block steps ran on completion.
    assert is_integer(Chain.get_block!(0).tallies_version)

    # One capped try whole (REST: too large), then the stream; no per-tx path.
    assert RpcStub.calls(:rest_block) == [[big.hash]]
    assert RpcStub.calls(:rest_block_stream) == [[big.hash]]
    no_per_tx_calls!()
  end

  test "a block whose stored size is over the cap goes straight to the stream", %{big: big} do
    block = header(big, %{size: byte_size(big.bytes)})
    RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

    assert :ok = FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

    assert Chain.get_block!(0).sync_state == "completed"
    assert stored() == length(big.txids)
    assert RpcStub.calls(:rest_block) == []
    no_per_tx_calls!()
  end

  test "bounded runs resume from the saved offset, and only the last run completes it",
       %{big: big} do
    Application.put_env(:bitblocks, :tx_fetch_run_ms, 0)
    block = header(big)
    RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})
    {:ok, job} = Oban.insert(FetchTransactionsWorker.new(%{block_hash: block.hash}))

    assert {:snooze, 1} = perform(job)
    assert Repo.reload!(job).meta["stream"] == %{"hash" => big.hash, "offset" => 100}
    assert stored() == 100
    assert Chain.get_block!(0).sync_state == "txs_syncing"

    # The next run reads the block again, checks the first 100, stores 100 more.
    assert {:snooze, 1} = perform(job)
    assert Repo.reload!(job).meta["stream"]["offset"] == 200
    assert stored() == 200
    assert Chain.get_block!(0).sync_state == "txs_syncing"

    result =
      Enum.reduce_while(1..10, nil, fn _, _ ->
        case perform(job) do
          :ok -> {:halt, :ok}
          other -> {:cont, other}
        end
      end)

    assert result == :ok
    assert Chain.get_block!(0).sync_state == "completed"
    assert stored() == length(big.txids)
    # A resumed run goes straight to the stream, never the capped whole fetch again.
    assert RpcStub.calls(:rest_block) == [[big.hash]]
    no_per_tx_calls!()
  end

  test "a resumed run refills a tx that went missing from the stored region", %{big: big} do
    Application.put_env(:bitblocks, :tx_fetch_run_ms, 0)
    block = header(big, %{size: byte_size(big.bytes)})
    RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})
    {:ok, job} = Oban.insert(FetchTransactionsWorker.new(%{block_hash: block.hash}))

    assert {:snooze, 1} = perform(job)
    gone = Enum.at(big.txids, 7)
    Repo.delete_all(from(t in Chain.Transaction, where: t.txid == ^gone))

    Application.put_env(:bitblocks, :tx_fetch_run_ms, 60_000)
    assert :ok = perform(job)
    assert Chain.get_block!(0).sync_state == "completed"
    assert Chain.get_transaction(gone)
    assert stored() == length(big.txids)
  end

  test "a read cut off mid-block leaves the block failed, keeps what it stored, and retries",
       %{big: big} do
    block = header(big, %{size: byte_size(big.bytes)})
    cut = div(byte_size(big.bytes), 2)
    RpcStub.stub_rest_block(big.hash, {:partial, binary_part(big.bytes, 0, cut), :timeout})
    {:ok, job} = Oban.insert(FetchTransactionsWorker.new(%{block_hash: block.hash}))

    assert {:snooze, 60} = perform(job)

    failed = Chain.get_block!(0)
    assert failed.sync_state == "failed"
    assert failed.tx_sync_attempts == 1
    assert failed.tx_sync_error =~ "connection_error"
    assert failed.tx_sync_error =~ ":timeout"

    # The chunks stored before the cut are kept, and the offset says so.
    kept = stored()
    assert kept >= 100
    assert Repo.reload!(job).meta["stream"]["offset"] == kept
    # A partial read is never handed to the per-tx path.
    no_per_tx_calls!()

    RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})
    assert :ok = perform(job)
    assert Chain.get_block!(0).sync_state == "completed"
    assert stored() == length(big.txids)
  end

  test "a stream that ends short is truncated: failed, not completed", %{big: big} do
    block = header(big, %{size: byte_size(big.bytes)})
    short = binary_part(big.bytes, 0, byte_size(big.bytes) - 1)
    RpcStub.stub_rest_block(big.hash, {:ok, short})

    assert {:snooze, 60} =
             FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

    failed = Chain.get_block!(0)
    assert failed.sync_state == "failed"
    assert failed.tx_sync_error =~ "truncated"
    no_per_tx_calls!()
  end

  test "a merkleroot mismatch fails the block, whatever was stored, and no other path takes it",
       %{big: big} do
    block = header(big, %{size: byte_size(big.bytes)})
    RpcStub.stub_rest_block(big.hash, {:ok, tamper(big.bytes)})
    {:ok, job} = Oban.insert(FetchTransactionsWorker.new(%{block_hash: block.hash}))

    assert {:snooze, 60} = perform(job)
    assert {:snooze, 120} = perform(job)

    failed = Chain.get_block!(0)
    assert failed.sync_state == "failed"
    assert failed.tx_sync_attempts == 2
    assert failed.tx_sync_error =~ "merkleroot_verification_failed"
    no_per_tx_calls!()
  end

  test "a tx over the per-tx limit fails the block loudly, never skipped", %{big: big} do
    Application.put_env(:bitblocks, :block_stream_max_tx_bytes, 50_000)
    block = header(big, %{size: byte_size(big.bytes)})
    RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

    assert {:snooze, 60} =
             FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

    failed = Chain.get_block!(0)
    assert failed.sync_state == "failed"
    assert failed.tx_sync_error =~ "tx_too_large"
    no_per_tx_calls!()
  end

  test "a block over the block limit fails loudly, before a request when its size is known",
       %{big: big} do
    Application.put_env(:bitblocks, :block_stream_max_block_bytes, 200_000)

    # Size unknown: REST says over the raw cap, the stream finds it over the limit.
    block = header(big)
    RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

    assert {:snooze, 60} =
             FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

    failed = Chain.get_block!(0)
    assert failed.sync_state == "failed"
    assert failed.tx_sync_error =~ "block_too_large"
    assert RpcStub.calls(:rest_block_stream) == [[big.hash]]

    # Size known: refused without reading it.
    RpcStub.clear()
    RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})
    {:ok, _} = failed |> Ecto.Changeset.change(size: byte_size(big.bytes)) |> Repo.update()

    assert {:snooze, 120} =
             FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

    assert Chain.get_block!(0).tx_sync_error =~ "block_too_large"
    assert RpcStub.calls(:rest_block_stream) == []
    no_per_tx_calls!()
  end

  describe "REST unavailable" do
    # The real genesis block, its row claiming 64 MB so it is over the cap.
    @genesis_hash "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"
    @genesis_txid "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
    @genesis_raw "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

    setup do
      block =
        block_fixture(%{
          height: 0,
          hash: @genesis_hash,
          merkleroot: @genesis_txid,
          num_tx: 1,
          size: 64 * 1024 * 1024,
          tx: [],
          sync_state: "header_only"
        })

      RpcStub.stub_getblock(@genesis_hash, 1, %{"hash" => @genesis_hash, "tx" => [@genesis_txid]})

      RpcStub.stub_getrawtransaction(@genesis_txid, 1, %{
        "txid" => @genesis_txid,
        "hex" => @genesis_raw,
        "blockhash" => @genesis_hash,
        "height" => 0,
        "version" => 1,
        "vin" => [%{"coinbase" => "04ffff001d0104", "sequence" => 4_294_967_295}],
        "vout" => []
      })

      %{block: block}
    end

    test "a REST 404 falls back to the txid list and per-chunk bodies", %{block: block} do
      RpcStub.stub_rest_block(@genesis_hash, {:error, {:http_error, 404}})

      assert :ok =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      assert Chain.get_block!(0).sync_state == "completed"
      assert Chain.get_transaction!(@genesis_txid)
      assert RpcStub.calls(:rest_block_stream) == [[@genesis_hash]]
      assert [[@genesis_hash, 1]] = RpcStub.calls(:getblock)
    end

    test "with the stream turned off, a large block takes the per-tx path", %{block: block} do
      Application.put_env(:bitblocks, :sync_block_stream, false)

      assert :ok =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      assert Chain.get_block!(0).sync_state == "completed"
      assert RpcStub.calls(:rest_block_stream) == []
    end
  end
end
