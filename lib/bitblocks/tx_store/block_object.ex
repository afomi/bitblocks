defmodule Bitblocks.TxStore.BlockObject do
  @moduledoc """
  A completed block's exact bytes in the tx store as one object,
  `blocks/<height>-<hash>.bin`, so every tx in it is in the store and is read
  back by range (docs/TX_STORAGE.md, step 1).

  ## Guarantees

    * **Only the block's own bytes are written.** The first 80 bytes must hash
      to the block hash, and the txs must fill the bytes exactly.
    * **A write is confirmed, not assumed.** After the put, the object is read
      back: its size must equal the block's, and its first 80 bytes (a ranged
      read) must hash to the block hash. Only then are the txs' `raw_offset`
      and `raw_length` set and `blocks.raw_object_stored_at` stamped, in one
      transaction.
    * **Never in the way of sync.** `store/3` returns an error and logs it; it
      never raises, and the block job ignores its result. A block left
      unstamped is found by `backfill/3`.

  ## Config

  `config :bitblocks, :store_block_objects, :auto | true | false`: `:auto`
  (the default) writes only while `Bitblocks.TxStore.ready?/0` is `:ok`, so a
  missing bucket never breaks sync; `false` turns it off.

  Blocks over the raw-block cap (`Chain.RawBlock.eligible?/1`, 32 MB) take the
  per-tx path and get no object here; reconcile counts them as missing.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Block, RawBlock, Transaction}
  alias Bitblocks.{Repo, TxStore}

  # Rows located per UPDATE: bounded IN lists at any block size.
  @locate_chunk 5_000

  @doc "The object key for a block."
  @spec key(Block.t() | %{height: integer(), hash: String.t()}) :: String.t()
  def key(%{height: height, hash: hash}), do: key(height, hash)

  @doc "The object key for a block at `height` with `hash`."
  def key(height, hash), do: "blocks/#{height}-#{String.downcase(hash)}.bin"

  @doc "Whether completed blocks' objects are written (see Config)."
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:bitblocks, :store_block_objects, :auto) do
      :auto -> TxStore.ready?() == :ok
      setting -> setting == true
    end
  end

  @doc """
  Writes `block_bytes` as `block`'s object, verifies the write, then locates
  its txs and stamps the block. Idempotent: an object already there with the
  right size is verified, not rewritten. `txs` is `RawBlock.parse/1`'s list,
  when the caller already has it.

  Returns `{:ok, %{bytes: n, located: rows}}` or `{:error, reason}`.
  """
  @spec store(Block.t(), binary(), [{String.t(), binary()}] | nil) ::
          {:ok, map()} | {:error, term()}
  def store(%Block{} = block, block_bytes, txs \\ nil) when is_binary(block_bytes) do
    key = key(block)

    with :ok <- check_header(block_bytes, block.hash),
         {:ok, txs} <- if(txs, do: {:ok, txs}, else: RawBlock.parse(block_bytes)),
         {:ok, located} <- RawBlock.locate(block_bytes, txs),
         :ok <- put(key, block_bytes),
         :ok <- verify(key, byte_size(block_bytes), block.hash),
         {:ok, rows} <- stamp(block, located) do
      {:ok, %{bytes: byte_size(block_bytes), located: rows}}
    else
      {:error, reason} = error ->
        Logger.warning(
          "TxStore: block #{block.height} object #{key} not stored: #{inspect(reason)}"
        )

        error
    end
  rescue
    e ->
      Logger.error("TxStore: block #{block.height} object crashed: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  # Write-once: an object of the right size is kept (and still verified).
  defp put(key, bytes) do
    if adapter().size(key) == {:ok, byte_size(bytes)},
      do: :ok,
      else: adapter().put(key, bytes)
  end

  @doc """
  Re-reads `block`'s object: `:ok` only when it has `size` bytes and its first
  80 bytes hash to the block hash. Never trusts the put's return.
  """
  @spec verify(String.t(), non_neg_integer(), String.t()) :: :ok | {:error, term()}
  def verify(key, size, hash) do
    with {:size, {:ok, ^size}} <- {:size, adapter().size(key)},
         {:ok, header} <- adapter().get_range(key, 0, 80) do
      check_header(header, hash)
    else
      {:size, {:ok, other}} -> {:error, {:size_mismatch, other, size}}
      {:size, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_header(<<header::binary-80, _::binary>>, hash) do
    if TxStore.txid(header) == String.downcase(hash),
      do: :ok,
      else: {:error, :block_hash_mismatch}
  end

  defp check_header(_, _), do: {:error, :invalid_block}

  # Offsets on the block's own rows that lack them (a tx stored under another
  # block, e.g. a BIP30 duplicate coinbase, is located through that block),
  # then the stamp, with updated_at so chain tiles see the change. The sync
  # writes offsets at insert, so for a block it just fetched this updates no
  # row; rows stored before that (Release.store_block_objects/3) get them here.
  defp stamp(block, located) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(
      fn ->
        rows =
          located
          |> Enum.chunk_every(@locate_chunk)
          |> Enum.reduce(0, fn chunk, acc ->
            {txids, offsets, lengths} = unzip3(chunk)

            {n, _} =
              Repo.update_all(
                from(t in Transaction,
                  join:
                    l in fragment(
                      "SELECT * FROM unnest(?::text[], ?::bigint[], ?::bigint[]) AS l(txid, raw_offset, raw_length)",
                      ^txids,
                      ^offsets,
                      ^lengths
                    ),
                  on: t.txid == l.txid,
                  where: t.block_hash == ^block.hash and is_nil(t.raw_offset),
                  update: [set: [raw_offset: l.raw_offset, raw_length: l.raw_length]]
                ),
                []
              )

            acc + n
          end)

        Repo.update_all(
          from(b in Block, where: b.id == ^block.id),
          set: [
            raw_object_stored_at: now,
            updated_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
          ]
        )

        rows
      end,
      timeout: :timer.minutes(2)
    )
  end

  defp unzip3(list) do
    {a, b, c} =
      Enum.reduce(list, {[], [], []}, fn {x, y, z}, {a, b, c} -> {[x | a], [y | b], [z | c]} end)

    {Enum.reverse(a), Enum.reverse(b), Enum.reverse(c)}
  end

  # -- Backfill ------------------------------------------------------------------

  @doc """
  Writes objects for completed blocks from `from` to `to` that have none,
  refetching each raw block from the node (`RawBlock.fetch/2`: REST, else
  `getblock(hash, 0)`). Bounded and resumable: at most `limit` blocks per call,
  lowest height first, and a stamped block is never picked again, so the next
  call carries on.

  **Dry run by default**: counts what it would do and touches neither the node
  nor the store. `apply: true` writes.

  Options: `apply:` (false), `limit:` (500 blocks), `max_failures:` (3: stops
  after that many failures in a row, e.g. a node refusing RPC, and says so).

  Returns `%{from, to, applied, missing, eligible, too_large, attempted,
  stored, failed, failures, stopped}`; `missing` is every completed block in
  the range without an object, `too_large` the part of it over the raw-block
  cap (per-tx path, never written here), `failures` the first few
  `{height, reason}`, and `stopped` nil or why the run stopped early.
  """
  @spec backfill(non_neg_integer(), non_neg_integer(), keyword()) :: map()
  def backfill(from, to, opts \\ []) when is_integer(from) and is_integer(to) do
    apply? = Keyword.get(opts, :apply, false)
    limit = Keyword.get(opts, :limit, 500)
    max_failures = Keyword.get(opts, :max_failures, 3)

    missing_q =
      from(b in Block,
        where:
          b.height >= ^from and b.height <= ^to and b.sync_state == "completed" and
            is_nil(b.raw_object_stored_at)
      )

    missing = Repo.aggregate(missing_q, :count)

    candidates = Repo.all(from b in missing_q, order_by: b.height, limit: ^limit)
    {eligible, too_large} = Enum.split_with(candidates, &RawBlock.eligible?/1)

    base = %{
      from: from,
      to: to,
      applied: apply?,
      missing: missing,
      considered: length(candidates),
      eligible: length(eligible),
      too_large: length(too_large),
      attempted: 0,
      stored: 0,
      failed: 0,
      failures: [],
      stopped: nil
    }

    cond do
      not apply? ->
        base

      (ready = TxStore.ready?()) != :ok ->
        %{base | stopped: {:store_not_ready, elem(ready, 1)}}

      true ->
        eligible
        |> Enum.reduce_while({base, 0}, fn block, {acc, in_a_row} ->
          acc = %{acc | attempted: acc.attempted + 1}

          case fetch_and_store(block) do
            {:ok, _} ->
              {:cont, {%{acc | stored: acc.stored + 1}, 0}}

            {:error, reason} ->
              acc = %{
                acc
                | failed: acc.failed + 1,
                  failures: Enum.take(acc.failures ++ [{block.height, reason}], 10)
              }

              if in_a_row + 1 >= max_failures,
                do: {:halt, {%{acc | stopped: {:failures_in_a_row, in_a_row + 1, reason}}, 0}},
                else: {:cont, {acc, in_a_row + 1}}
          end
        end)
        |> elem(0)
    end
  end

  defp fetch_and_store(block) do
    case RawBlock.fetch(block) do
      {:ok, txs, %{raw: bytes}} -> store(block, bytes, txs)
      {:error, reason} -> {:error, {:fetch, reason}}
    end
  rescue
    e -> {:error, {:fetch, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:fetch, {:exit, reason}}}
  end

  defp adapter,
    do:
      Application.get_env(:bitblocks, TxStore, [])
      |> Keyword.get(:adapter, TxStore.S3)
end
