defmodule Bitblocks.Chain.BlockStreamTest do
  # A block of any size read as a stream in bounded memory (#66), from a
  # local node's REST interface that hands it over in small chunks, so txs
  # and their fields split across chunks.
  use ExUnit.Case, async: false

  alias Bitblocks.Chain.{Block, BlockStream, MerkleBuilder, MerkleVerifier}
  alias Bitblocks.SyntheticBlock

  @blocks __MODULE__.Blocks

  defmodule Node do
    @behaviour Plug

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/rest/block/" <> file} = conn, _opts) do
      hash = String.trim_trailing(file, ".bin")

      case Agent.get(Bitblocks.Chain.BlockStreamTest.Blocks, &Map.get(&1, hash)) do
        nil ->
          Plug.Conn.send_resp(conn, 404, "")

        %{drops: n} when n > 0 ->
          # Close the connection before a single byte, as a node does with
          # a keep-alive connection it has dropped as idle.
          Agent.update(Bitblocks.Chain.BlockStreamTest.Blocks, fn blocks ->
            Map.update!(blocks, hash, &%{&1 | drops: n - 1})
          end)

          Process.exit(self(), :kill)

        served ->
          serve(Plug.Conn.send_chunked(conn, 200), served)
      end
    end

    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")

    defp serve(conn, %{bytes: bytes, chunk: chunk} = served) do
      Enum.reduce_while(slices(bytes, chunk), {conn, 0}, fn slice, {conn, sent} ->
        if served[:stall_after] && sent >= served.stall_after, do: Process.sleep(served.stall_ms)

        case Plug.Conn.chunk(conn, slice) do
          {:ok, conn} -> {:cont, {conn, sent + byte_size(slice)}}
          {:error, _} -> {:halt, {conn, sent}}
        end
      end)
      |> elem(0)
    end

    defp slices(bytes, chunk) do
      Stream.unfold(bytes, fn
        <<>> -> nil
        rest when byte_size(rest) <= chunk -> {rest, <<>>}
        <<slice::binary-size(chunk), rest::binary>> -> {slice, rest}
      end)
    end
  end

  setup do
    start_supervised!(%{
      id: @blocks,
      start: {Agent, :start_link, [fn -> %{} end, [name: @blocks]]}
    })

    server = start_supervised!({Bandit, plug: Node, ip: :loopback, port: 0, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    saved =
      for key <- [:rest_url, :bitcoinsv_cli, :bitcoin_rpc_recv_timeout_ms],
          do: {key, Application.fetch_env(:bitblocks, key)}

    Application.put_env(:bitblocks, :rest_url, "http://127.0.0.1:#{port}")
    Application.put_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:bitblocks, key, v)
          :error -> Application.delete_env(:bitblocks, key)
        end
      end
    end)
  end

  # Builds a block in the Agent's process and serves it under its hash, so
  # the test process never holds the block's bytes. Returns its metadata.
  defp serve_block(target_bytes, opts \\ []) do
    {chunk, opts} = Keyword.pop(opts, :chunk, 4_093)
    {keep_txids, opts} = Keyword.pop(opts, :txids, true)

    Agent.get_and_update(@blocks, fn blocks ->
      block = SyntheticBlock.build(target_bytes, opts)
      meta = block |> Map.delete(:bytes) |> Map.put(:tx_count, length(block.txids))
      # A big block's txids would be most of what the test process holds.
      meta = if keep_txids, do: meta, else: Map.delete(meta, :txids)
      {meta, Map.put(blocks, block.hash, %{bytes: block.bytes, chunk: chunk})}
    end)
  end

  # Changes what is served under `hash`.
  defp serve_as(hash, fun) do
    Agent.update(@blocks, fn blocks -> Map.update!(blocks, hash, fun) end)
  end

  defp block(meta, attrs \\ %{}) do
    struct(
      Block,
      Map.merge(
        %{hash: meta.hash, merkleroot: meta.merkleroot, num_tx: meta.tx_count, height: 1},
        attrs
      )
    )
  end

  defp collect(block, opts \\ []) do
    BlockStream.each_tx(
      block,
      [],
      fn {txid, bytes}, acc ->
        # Each tx's bytes really are the tx: they hash to its txid.
        ^txid = SyntheticBlock.display(SyntheticBlock.sha256d(bytes))
        [txid | acc]
      end,
      opts
    )
  end

  test "hands over every tx in order, its txids rebuilding the header's merkleroot" do
    meta = serve_block(3_000_000)

    assert {:ok, txids, stats} = collect(block(meta))
    assert Enum.reverse(txids) == meta.txids
    assert stats.txs == length(meta.txids)
    assert stats.bytes > 3_000_000
    assert stats.largest_tx_bytes == meta.largest_tx
    # Thousands of 4 KB chunks: every tx boundary and most fields split.
    assert div(stats.bytes, 4_093) > 700
    assert meta.largest_tx > 65_536
  end

  test "a block whose count isn't the header's num_tx fails before any tx is handed over" do
    meta = serve_block(200_000)
    test = self()

    assert {:error, {:tx_count_mismatch, _, 1}} =
             BlockStream.each_tx(block(meta, %{num_tx: 1}), nil, fn tx, _ -> send(test, tx) end)

    refute_received _
  end

  test "a tampered script byte, well away from any length, is a merkle mismatch" do
    meta = serve_block(300_000, big_every: 5)

    # The OP_RETURN payload of a big tx is a long run of 0x42: flip one.
    serve_as(meta.hash, fn %{bytes: bytes} = served ->
      {at, _} = :binary.match(bytes, :binary.copy(<<0x42>>, 1_000))
      <<head::binary-size(at + 500), byte, tail::binary>> = bytes
      %{served | bytes: <<head::binary, Bitwise.bxor(byte, 1), tail::binary>>}
    end)

    assert {:error, {:merkleroot_verification_failed, :merkleroot_mismatch}} =
             collect(block(meta))
  end

  test "a header that doesn't hash to the block's hash fails at once" do
    meta = serve_block(100_000)

    serve_as(meta.hash, fn %{bytes: <<v, rest::binary>>} = served ->
      %{served | bytes: <<Bitwise.bxor(v, 1), rest::binary>>}
    end)

    assert {:error, :block_hash_mismatch} = collect(block(meta))
  end

  test "a truncated stream is an error, however much arrived" do
    meta = serve_block(400_000)

    serve_as(meta.hash, fn %{bytes: bytes} = served ->
      %{served | bytes: binary_part(bytes, 0, byte_size(bytes) - 10)}
    end)

    assert {:error, {:truncated, _bytes}} = collect(block(meta))

    serve_as(meta.hash, fn served -> %{served | bytes: binary_part(served.bytes, 0, 50)} end)
    assert {:error, {:truncated, 50}} = collect(block(meta))
  end

  test "bytes after the last tx are an error" do
    meta = serve_block(100_000)
    serve_as(meta.hash, fn served -> %{served | bytes: served.bytes <> <<0>>} end)

    assert {:error, :trailing_bytes} = collect(block(meta))
  end

  test "a tx over the per-tx maximum fails the block, as soon as its size is known" do
    meta = serve_block(2_000_000, big_tx_bytes: 1_500_000)
    test = self()

    assert {:error, {:tx_too_large, 1, size}} =
             BlockStream.each_tx(
               block(meta),
               0,
               fn _tx, n ->
                 send(test, :tx)
                 n + 1
               end,
               max_tx_bytes: 1_000_000
             )

    assert size > 1_000_000
    # Only the coinbase, before it, was handed over.
    assert_received :tx
    refute_received :tx

    assert {:ok, _, %{largest_tx_bytes: largest}} = collect(block(meta), max_tx_bytes: 2_000_000)
    assert largest >= 1_500_000
  end

  test "fun's {:halt, acc} stops the read there, unverified, over the real client" do
    meta = serve_block(3_000_000)

    stop_at_ten = fn {txid, _bytes}, acc ->
      acc = [txid | acc]
      if length(acc) == 10, do: {:halt, acc}, else: acc
    end

    assert {:halted, txids, stats} = BlockStream.each_tx(block(meta), [], stop_at_ten)
    assert Enum.reverse(txids) == Enum.take(meta.txids, 10)
    assert stats.txs == 10
    assert stats.bytes < 3_000_000
  end

  test "a block over the block maximum fails, before a request when its size is known" do
    meta = serve_block(3_000_000)

    assert {:error, {:block_too_large, bytes}} =
             collect(block(meta), max_block_bytes: 1_000_000)

    assert bytes > 1_000_000

    assert {:error, {:block_too_large, 5_000_000}} =
             collect(block(meta, %{size: 5_000_000}), max_block_bytes: 1_000_000)
  end

  test "no REST is a 404, with no fallback" do
    assert {:error, {:http_error, 404}} =
             collect(%Block{hash: String.duplicate("ab", 32), num_tx: 1, height: 1})
  end

  test "a connection closed before any bytes is tried once more, and then counts" do
    meta = serve_block(200_000)
    serve_as(meta.hash, &Map.put(&1, :drops, 1))
    assert {:ok, txids, %{txs: n}} = collect(block(meta))
    assert n == meta.tx_count and length(txids) == n

    serve_as(meta.hash, &Map.put(&1, :drops, 2))

    assert {:error, {{:connection_error, :closed}, after_bytes: 0, after_ms: _}} =
             collect(block(meta))
  end

  test "a chunk slower than the receive timeout ends the read, saying how far it got" do
    meta = serve_block(200_000)
    serve_as(meta.hash, &Map.merge(&1, %{stall_after: 50_000, stall_ms: 600}))
    Application.put_env(:bitblocks, :bitcoin_rpc_recv_timeout_ms, 200)

    assert {:error, {{:connection_error, :timeout}, after_bytes: bytes, after_ms: ms}} =
             collect(block(meta))

    assert bytes >= 50_000 and bytes < 200_000
    assert ms >= 200
  end

  # #66's acceptance test: a block far over the 32 MB raw cap parses with
  # the reader's memory under a set bound.
  @tag timeout: 300_000
  test "a 40 MB block streams with the reader's memory under 8 MB" do
    meta = serve_block(40 * 1024 * 1024, chunk: 65_536, txids: false)
    me = self()

    sample = fn ->
      {:memory, heap} = :erlang.process_info(me, :memory)
      {:binary, bins} = :erlang.process_info(me, :binary)
      # Off-heap (refc) binaries this process references, each counted once.
      off_heap = bins |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sum_by(&elem(&1, 1))
      heap + off_heap
    end

    started = System.monotonic_time(:millisecond)

    assert {:ok, {count, peak}, stats} =
             BlockStream.each_tx(block(meta), {0, 0}, fn _tx, {n, peak} ->
               peak = if rem(n, 20) == 0, do: max(peak, sample.()), else: peak
               {n + 1, peak}
             end)

    ms = System.monotonic_time(:millisecond) - started
    assert count == meta.tx_count
    assert stats.bytes > 40 * 1024 * 1024

    IO.puts(
      "\n  BlockStream: #{stats.bytes} bytes, #{count} txs in #{ms} ms " <>
        "(#{Float.round(stats.bytes / 1_048_576 / max(ms, 1) * 1000, 1)} MB/s); " <>
        "peak reader memory #{Float.round(peak / 1_048_576, 2)} MB"
    )

    assert peak < 8 * 1024 * 1024
  end

  describe "MerkleBuilder" do
    test "agrees with MerkleVerifier and a level-by-level build for every count to 70" do
      for n <- 1..70 do
        hashes = for _ <- 1..n, do: :crypto.strong_rand_bytes(32)
        builder = Enum.reduce(hashes, MerkleBuilder.new(), &MerkleBuilder.push(&2, &1))
        {:ok, root} = MerkleBuilder.root(builder)

        assert root == SyntheticBlock.merkle_root(hashes), "n = #{n}"

        assert :ok ==
                 MerkleVerifier.verify(
                   Enum.map(hashes, &SyntheticBlock.display/1),
                   SyntheticBlock.display(root)
                 )

        assert MerkleBuilder.count(builder) == n
      end
    end

    test "an empty builder has no root" do
      assert {:error, :empty_txid_list} = MerkleBuilder.root(MerkleBuilder.new())
    end
  end
end
