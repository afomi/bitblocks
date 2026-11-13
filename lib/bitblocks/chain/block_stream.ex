defmodule Bitblocks.Chain.BlockStream do
  @moduledoc """
  A block of any size read from the node's REST interface as a stream and
  split into its transactions as their bytes arrive, in bounded memory (#66).

  `Chain.RawBlock` holds a block whole, so it takes blocks up to 32 MB.
  Blocks near the BSV tip are often hundreds of MB, some over a GB. This
  reads `GET /rest/block/<hash>.bin` chunk by chunk (Finch streaming) and
  hands each tx to the caller as soon as it is complete, keeping only:

    * the bytes of the tx being assembled and the chunk that just arrived;
    * a merkle builder, one partial hash per tree level
      (`Chain.MerkleBuilder`), instead of the txid list (a 4M-tx block's
      would be about 128 MB).

  So peak memory is roughly the largest tx (twice it, briefly, when a tx
  spanning chunks is joined) plus a chunk, whatever the block's size.

  ## Checks, and what the caller may trust
  The first 80 bytes must hash to the block's hash, and the tx count must
  match the block's `num_tx` when known; both fail before any tx is handed
  over. The txids, each the double SHA-256 of its own bytes, must rebuild the
  header's merkleroot, and the bytes must end exactly after the last tx;
  those are known only at the end. So **everything `fun` saw is unverified
  until `each_tx/4` returns `{:ok, ...}`**: on `{:error, _}` the caller
  discards it and writes nothing.

  ## Limits
    * `:block_stream_max_tx_bytes` (option `:max_tx_bytes`), default 256 MB:
      the largest single tx read. BSV's consensus limit since Genesis is 1 GB
      and miners' default policy is far lower (10 MB), so 256 MB covers every
      tx seen in practice while keeping one tx's worth of memory sane. A
      larger tx fails the block with `{:tx_too_large, index, size}` as soon
      as its size is known, never skipped; raise the setting to read it.
    * `:block_stream_max_block_bytes` (option `:max_block_bytes`), default
      1 GiB: the largest block read. A block whose stored `size` is larger
      fails before any request, and one that turns out larger fails with
      `{:block_too_large, bytes}` once that many bytes have arrived; never
      skipped, raise the setting to read it.
    * Each chunk must arrive within the node's RPC receive timeout
      (`:bitcoin_rpc_recv_timeout_ms`, 60 s default); the whole read has no
      bound of its own, since a GB block takes as long as it takes.
    * REST only (`rest=1`): no REST is `{:error, {:http_error, 404}}`. There
      is no `getblock(hash, 0)` fallback, since that returns the block as one
      hex string, twice its size, held whole.

  ## Stopping early
  `fun` may return `{:halt, acc}` to stop the read after that tx; `each_tx/4`
  then returns `{:halted, acc, stats}`, with nothing verified past the
  header and the tx count. The sync's block job does this at the end of a
  bounded run, and reads the block again on its next run.

  Used by `Bitblocks.Support.Scan` and by the sync's
  `Bitblocks.Workers.FetchTransactionsWorker`, for blocks over the raw-block
  cap.
  """

  alias Bitblocks.Chain.{Block, MerkleBuilder}

  @default_max_tx_bytes 256 * 1024 * 1024
  @default_max_block_bytes 1024 * 1024 * 1024

  @typedoc "A tx as handed to `fun`: display txid and the tx's exact bytes."
  @type tx :: {String.t(), binary()}

  @doc """
  Streams `block` from the node and calls `fun.({txid, tx_bytes}, acc)` for
  each tx in block order, threading `acc`. `tx_bytes` may be a sub-binary of
  a received chunk; `:binary.copy/1` it if you keep it.

  Returns `{:ok, acc, stats}` once every check passed, with `stats`
  `%{source: :rest, bytes: n, txs: n, largest_tx_bytes: n, ms: n}`;
  `{:halted, acc, stats}` when `fun` returned `{:halt, acc}` (see Stopping
  early); or `{:error, reason}`, after which `acc` and everything `fun` saw
  must be treated as unverified.

  Options: `:max_tx_bytes` and `:max_block_bytes` (see Limits).
  """
  @spec each_tx(Block.t(), acc, (tx(), acc -> acc | {:halt, acc}), keyword()) ::
          {:ok, acc, map()} | {:halted, acc, map()} | {:error, term()}
        when acc: term()
  def each_tx(%Block{} = block, acc, fun, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :max_block_bytes, &max_block_bytes/0)
    max_block = opts[:max_block_bytes]

    case block.size do
      size when is_integer(size) and size > max_block ->
        {:error, {:block_too_large, size}}

      _ ->
        read_retrying(block, acc, fun, opts)
    end
  end

  defp read_retrying(block, acc, fun, opts) do
    case read(block, acc, fun, opts) do
      # Closed before a single byte: most often a pooled keep-alive connection
      # the node had already dropped as idle. A GET is safe to repeat, so it
      # is tried once more on a fresh connection before the error counts.
      {:error, {{:connection_error, :closed}, after_bytes: 0, after_ms: _}} ->
        read(block, acc, fun, opts)

      result ->
        result
    end
  end

  defp read(block, acc, fun, opts) do
    started = System.monotonic_time(:millisecond)
    state = new(block, Keyword.get(opts, :max_tx_bytes, max_tx_bytes()), opts[:max_block_bytes])

    # Bytes received, kept outside the stream's accumulator so a transport
    # failure mid-block can still say how far it got (time limit or size?).
    received = :counters.new(1, [])

    feed = fn chunk, {state, acc} ->
      :counters.add(received, 1, byte_size(chunk))

      case push(state, chunk, acc, fun) do
        {:ok, state, acc} -> {:cont, {state, acc}}
        {:halt, state, acc} -> {:halt, {{:halted, state}, acc}}
        {:error, reason} -> {:halt, {{:error, reason}, acc}}
      end
    end

    case rpc().rest_block_stream(block.hash, {state, acc}, feed) do
      {:ok, {{:error, reason}, _acc}} ->
        {:error, reason}

      {:ok, {{:halted, state}, acc}} ->
        {:halted, acc, stats(state, started)}

      {:ok, {state, acc}} ->
        with :ok <- finish(state), do: {:ok, acc, stats(state, started)}

      # How far it got and how long it took tell a stale connection (0 bytes,
      # at once), a server timeout (0 bytes, at a fixed time) and a size
      # limit (a fixed byte count) apart.
      {:error, {:connection_error, _} = reason} ->
        {:error,
         {reason,
          after_bytes: :counters.get(received, 1),
          after_ms: System.monotonic_time(:millisecond) - started}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stats(state, started) do
    %{
      source: :rest,
      bytes: state.bytes,
      txs: state.count,
      largest_tx_bytes: state.largest,
      ms: System.monotonic_time(:millisecond) - started
    }
  end

  # -- The parser ------------------------------------------------------------------
  #
  # `pending` holds bytes received but not yet parsed, newest first, starting
  # at an item boundary (header, count, or a field of the current tx). It is
  # joined into one binary only once it holds `need` bytes, the least that
  # lets the next item complete, so a 100 MB script is joined once, not once
  # per chunk. `tx_parts` holds the current tx's parsed bytes, newest first,
  # and `steps` says where in its structure the parse stands.

  defp new(block, max_tx, max_block) do
    %{
      hash: String.downcase(block.hash),
      num_tx: block.num_tx,
      max_tx: max_tx,
      max_block: max_block,
      phase: :header,
      pending: [],
      pending_size: 0,
      need: 80,
      remaining: 0,
      count: 0,
      tx_parts: [],
      tx_size: 0,
      steps: :version,
      merkle: MerkleBuilder.new(),
      root: nil,
      bytes: 0,
      largest: 0
    }
  end

  defp push(state, chunk, acc, fun) do
    size = byte_size(chunk)

    state = %{
      state
      | pending: [chunk | state.pending],
        pending_size: state.pending_size + size,
        bytes: state.bytes + size
    }

    cond do
      state.bytes > state.max_block ->
        {:error, {:block_too_large, state.bytes}}

      state.pending_size < state.need ->
        {:ok, state, acc}

      true ->
        buf =
          case state.pending do
            [one] -> one
            many -> join(many)
          end

        advance(%{state | pending: [], pending_size: 0}, buf, acc, fun)
    end
  end

  defp advance(%{phase: :header} = state, buf, acc, fun) do
    case buf do
      <<header::binary-80, rest::binary>> ->
        <<_version::binary-4, _prev::binary-32, root::binary-32, _::binary>> = header

        if display(sha256d(header)) == state.hash,
          do: advance(%{state | phase: :count, root: root}, rest, acc, fun),
          else: {:error, :block_hash_mismatch}

      _ ->
        stash(state, buf, 80, acc)
    end
  end

  defp advance(%{phase: :count} = state, buf, acc, fun) do
    case varint(buf) do
      {:ok, len, count} ->
        if is_integer(state.num_tx) and state.num_tx > 0 and count != state.num_tx do
          {:error, {:tx_count_mismatch, count, state.num_tx}}
        else
          <<_::binary-size(len), rest::binary>> = buf
          phase = if count == 0, do: :done, else: :txs
          advance(%{state | phase: phase, remaining: count}, rest, acc, fun)
        end

      {:more, need} ->
        stash(state, buf, need, acc)
    end
  end

  defp advance(%{phase: :txs} = state, buf, acc, fun) do
    case walk(state.steps, buf, 0) do
      {:done, consumed} when state.tx_size + consumed > state.max_tx ->
        {:error, {:tx_too_large, state.count, state.tx_size + consumed}}

      {:done, consumed} ->
        <<last::binary-size(consumed), rest::binary>> = buf
        tx = if state.tx_parts == [], do: last, else: join([last | state.tx_parts])
        hash = sha256d(tx)

        {acc, halt?} =
          case fun.({display(hash), tx}, acc) do
            {:halt, acc} -> {acc, true}
            acc -> {acc, false}
          end

        state = %{
          state
          | merkle: MerkleBuilder.push(state.merkle, hash),
            count: state.count + 1,
            remaining: state.remaining - 1,
            largest: max(state.largest, byte_size(tx)),
            tx_parts: [],
            tx_size: 0,
            steps: :version
        }

        state = if state.remaining == 0, do: %{state | phase: :done}, else: state
        if halt?, do: {:halt, state, acc}, else: advance(state, rest, acc, fun)

      {:more, consumed, need, steps} ->
        tx_size = state.tx_size + consumed

        if tx_size + need > state.max_tx do
          {:error, {:tx_too_large, state.count, tx_size + need}}
        else
          <<part::binary-size(consumed), rest::binary>> = buf
          parts = if consumed == 0, do: state.tx_parts, else: [part | state.tx_parts]
          stash(%{state | tx_parts: parts, tx_size: tx_size, steps: steps}, rest, need, acc)
        end
    end
  end

  defp advance(%{phase: :done} = state, <<>>, acc, _fun), do: {:ok, state, acc}
  defp advance(%{phase: :done}, _buf, _acc, _fun), do: {:error, :trailing_bytes}

  defp stash(state, <<>>, need, acc), do: {:ok, %{state | need: need}, acc}

  defp stash(state, rest, need, acc),
    do: {:ok, %{state | pending: [rest], pending_size: byte_size(rest), need: need}, acc}

  defp join(parts_newest_first), do: parts_newest_first |> Enum.reverse() |> IO.iodata_to_binary()

  defp finish(%{phase: :done, pending_size: 0} = state) do
    case MerkleBuilder.root(state.merkle) do
      {:ok, root} when root == state.root ->
        :ok

      {:ok, _other} ->
        {:error, {:merkleroot_verification_failed, :merkleroot_mismatch}}

      {:error, reason} ->
        {:error, {:merkleroot_verification_failed, reason}}
    end
  end

  defp finish(state), do: {:error, {:truncated, state.bytes}}

  # -- One tx's structure, resumable at any field ------------------------------------
  #
  # The same layout `RawBlock` walks: version, inputs (outpoint, script,
  # sequence), outputs (sats, script), locktime. `walk/3` parses whole fields
  # from `pos` and returns `{:done, end}` when the tx is complete, or
  # `{:more, pos, need, steps}`: the bytes before `pos` are whole fields, the
  # field at `pos` needs `need` bytes, and `steps` resumes there.

  defp walk(steps, buf, pos) do
    available = byte_size(buf) - pos

    case field(steps, binary_part(buf, pos, available)) do
      {:ok, size, :done} -> {:done, pos + size}
      {:ok, size, next} -> walk(next, buf, pos + size)
      {:more, need} -> {:more, pos, need, steps}
    end
  end

  defp field(:version, <<_::binary-4, _::binary>>), do: {:ok, 4, {:count, :inputs}}
  defp field(:version, _), do: {:more, 4}

  defp field({:count, kind}, bin) do
    case varint(bin) do
      {:ok, len, n} -> {:ok, len, items(kind, n)}
      {:more, need} -> {:more, need}
    end
  end

  # outpoint, script length and script, sequence
  defp field({:inputs, n}, bin) do
    case script_at(bin, 36) do
      {:ok, script} -> sized(bin, 36 + script + 4, items(:inputs, n - 1))
      more -> more
    end
  end

  # sats, script length and script
  defp field({:outputs, n}, bin) do
    case script_at(bin, 8) do
      {:ok, script} -> sized(bin, 8 + script, items(:outputs, n - 1))
      more -> more
    end
  end

  defp field(:locktime, <<_::binary-4, _::binary>>), do: {:ok, 4, :done}
  defp field(:locktime, _), do: {:more, 4}

  defp sized(bin, total, next) when byte_size(bin) >= total, do: {:ok, total, next}
  defp sized(_bin, total, _next), do: {:more, total}

  # A field with no items left moves on without consuming anything.
  defp items(:inputs, 0), do: {:count, :outputs}
  defp items(:outputs, 0), do: :locktime
  defp items(kind, n), do: {kind, n}

  # The script's varint at `offset`: `{:ok, varint length + script length}`,
  # or `{:more, need}` when the varint itself isn't in yet.
  defp script_at(bin, offset) when byte_size(bin) <= offset, do: {:more, offset + 1}

  defp script_at(bin, offset) do
    <<_::binary-size(offset), rest::binary>> = bin

    case varint(rest) do
      {:ok, len, script} -> {:ok, len + script}
      {:more, need} -> {:more, offset + need}
    end
  end

  # `{:ok, varint byte length, value}` or `{:more, bytes needed}`.
  defp varint(<<0xFD, n::little-16, _::binary>>), do: {:ok, 3, n}
  defp varint(<<0xFD, _::binary>>), do: {:more, 3}
  defp varint(<<0xFE, n::little-32, _::binary>>), do: {:ok, 5, n}
  defp varint(<<0xFE, _::binary>>), do: {:more, 5}
  defp varint(<<0xFF, n::little-64, _::binary>>), do: {:ok, 9, n}
  defp varint(<<0xFF, _::binary>>), do: {:more, 9}
  defp varint(<<n, _::binary>>), do: {:ok, 1, n}
  defp varint(<<>>), do: {:more, 1}

  defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))

  defp display(hash),
    do: hash |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin() |> hex()

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp max_tx_bytes,
    do: Application.get_env(:bitblocks, :block_stream_max_tx_bytes, @default_max_tx_bytes)

  defp max_block_bytes,
    do: Application.get_env(:bitblocks, :block_stream_max_block_bytes, @default_max_block_bytes)

  defp rpc, do: Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)
end
