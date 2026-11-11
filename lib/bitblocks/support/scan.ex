defmodule Bitblocks.Support.Scan do
  @moduledoc """
  Gifts to the donation address in blocks the sync hasn't reached yet, read
  by us (#74, option 3), so a sponsor sees a gift soon after it confirms.

  Each block above `Sync.complete_through/0`, from the first block the
  address can have been paid in (`config :bitblocks, :support,
  scan_from_height:`), is read once by its raw bytes from our node
  (`Chain.RawBlock`: the same fetch the sync uses, checked against the
  header's merkle root). Its txs are counted by the same rule as the index
  (`Support.Received`: what a tx that spends from the address pays back
  there is change, not a gift), and one `support_block_scans` row records
  the block, its hash then, and the sats it gave.

  Coverage is contiguous and says how far it reaches: `coverage/2` is the
  highest block such that every block from the start is read, under the
  hash its header has now. A reorged block's row no longer matches, so the
  scan reads it again. A block over the raw-block cap stops the scan there,
  with a reason naming it, until large blocks stream (#66); it is never
  skipped. No third party is asked anything.

  `Bitblocks.Workers.SupportScanWorker` runs `run/1` every two minutes on
  its own lane, one block at a time, for a bounded time.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Block, RawBlock}
  alias Bitblocks.Repo
  alias Bitblocks.Support.{BlockScan, Received}

  @run_ms 60_000

  @doc "The donation address, or nil when none is configured."
  def address, do: config() |> Keyword.get(:bsv_address)

  @doc """
  The first block the scan reads, or nil when the scan isn't configured:
  the address can't have been paid before `scan_from_height`.
  """
  def scan_from_height, do: config() |> Keyword.get(:scan_from_height)

  @doc """
  Reads blocks for gifts, from the first one not yet covered, for up to
  `:run_ms` (#{@run_ms} ms). Returns `{:ok, stats}`: blocks read, sats
  found, and `stopped`: `:tip` (caught up), `:time`, or the reason a block
  couldn't be read.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) do
    address = Keyword.get(opts, :address, address())
    since = Keyword.get(opts, :since, scan_from_height())

    if is_binary(address) and is_integer(since) do
      complete_through = Bitblocks.Sync.complete_through()
      %{from: from, through: through} = coverage(address, complete_through, since)
      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :run_ms, @run_ms)
      started = System.monotonic_time(:millisecond)

      stats = read_from(address, through + 1, deadline, %{read: 0, gift_sats: 0})

      Logger.info(
        "support scan #{address}: read #{stats.read} blocks from #{max(from, through + 1)}, " <>
          "#{stats.gift_sats} sats given, stopped: #{inspect(stats.stopped)}, " <>
          "#{System.monotonic_time(:millisecond) - started} ms"
      )

      {:ok, stats}
    else
      {:ok, %{read: 0, gift_sats: 0, stopped: :not_configured}}
    end
  end

  defp read_from(address, height, deadline, stats) do
    cond do
      System.monotonic_time(:millisecond) >= deadline ->
        Map.put(stats, :stopped, :time)

      true ->
        case Repo.get_by(Block, height: height) do
          nil ->
            Map.put(stats, :stopped, :tip)

          block ->
            case read_block(address, block) do
              {:ok, sats} ->
                read_from(address, height + 1, deadline, %{
                  stats
                  | read: stats.read + 1,
                    gift_sats: stats.gift_sats + sats
                })

              {:error, reason} ->
                Map.put(stats, :stopped, {height, reason})
            end
        end
    end
  end

  @doc """
  Reads one block for gifts to `address` and records it. `{:ok, sats}`, or
  `{:error, reason}` with nothing recorded.
  """
  @spec read_block(String.t(), Block.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def read_block(address, %Block{} = block) do
    if RawBlock.eligible?(block) do
      with {:ok, txs, _stats} <- RawBlock.fetch(block) do
        gifts =
          for {txid, bytes} <- txs,
              json = RawBlock.tx_json(txid, bytes),
              sats = Received.sats(address, json["vin"], json["vout"]),
              sats > 0,
              do: {txid, sats}

        sats = Enum.sum_by(gifts, &elem(&1, 1))

        Repo.insert!(
          %BlockScan{
            height: block.height,
            block_hash: block.hash,
            address: address,
            gift_sats: sats,
            gift_txids: Enum.map(gifts, &elem(&1, 0)),
            scanned_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          on_conflict: {:replace, [:block_hash, :gift_sats, :gift_txids, :scanned_at]},
          conflict_target: [:address, :height]
        )

        {:ok, sats}
      end
    else
      {:error, :block_too_large}
    end
  end

  @doc """
  How far the scan reaches above `complete_through`: `%{from: f, through: t}`,
  where every block `f..t` is read under the hash its header has now (`t`
  is `f - 1` when none is). `f` is the block after `complete_through`, or
  `scan_from_height` when that is later: the blocks between can't hold a
  gift to an address that didn't exist yet.
  """
  @spec coverage(String.t(), integer(), integer()) :: %{from: integer(), through: integer()}
  def coverage(address, complete_through, since \\ scan_from_height()) do
    from = max(since || complete_through + 1, complete_through + 1)

    heights =
      from(s in BlockScan,
        join: b in Block,
        on: b.height == s.height and b.hash == s.block_hash,
        where: s.address == ^address and s.height >= ^from,
        order_by: [asc: s.height],
        select: s.height
      )
      |> Repo.all()

    through =
      Enum.reduce_while(heights, from - 1, fn h, last ->
        if h == last + 1, do: {:cont, h}, else: {:halt, last}
      end)

    %{from: from, through: through}
  end

  @doc "Sats given to `address` in the read blocks `lo..hi` (current hashes only)."
  @spec gifts(String.t(), integer(), integer()) :: non_neg_integer()
  def gifts(_address, lo, hi) when lo > hi, do: 0

  def gifts(address, lo, hi) do
    from(s in BlockScan,
      join: b in Block,
      on: b.height == s.height and b.hash == s.block_hash,
      where: s.address == ^address and s.height >= ^lo and s.height <= ^hi,
      select: fragment("coalesce(sum(?), 0)::bigint", s.gift_sats)
    )
    |> Repo.one()
  end

  @doc """
  Why the scan stops after `through`, in a sentence, or nil when it is at
  our tip.
  """
  @spec stop_reason(integer()) :: String.t() | nil
  def stop_reason(through) do
    case Repo.get_by(Block, height: through + 1) do
      nil ->
        nil

      block ->
        if RawBlock.eligible?(block),
          do: "Block #{block.height} is next to read.",
          else:
            "Block #{block.height} is larger than the scan reads whole; it counts once the sync reaches it."
    end
  end

  defp config, do: Application.get_env(:bitblocks, :support, [])
end
