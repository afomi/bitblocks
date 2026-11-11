defmodule Bitblocks.Support.Scan do
  @moduledoc """
  Gifts to the donation address in blocks the sync hasn't reached yet, read
  by us (#74, option 3), so a sponsor sees a gift soon after it confirms.

  Each block above `Sync.complete_through/0`, from the first block the
  address can have been paid in (`config :bitblocks, :support,
  scan_from_height:`), is read once by its raw bytes from our node
  (`Chain.RawBlock`: the same fetch the sync uses, checked against the
  header's merkle root). A block over the raw-block cap, as most near the
  tip are, streams through `Chain.BlockStream` instead: the same checks, in
  bounded memory, from the node's REST interface only (#66). Its txs are counted by the same rule as the index
  (`Support.Received`: what a tx that spends from the address pays back
  there is change, not a gift), and one `support_block_scans` row records
  the block, its hash then, and the sats it gave.

  Coverage is contiguous and says how far it reaches: `coverage/2` is the
  highest block such that every block from the start is read, under the
  hash its header has now. A reorged block's row no longer matches, so the
  scan reads it again. A block that can't be read (the node unreachable,
  REST off for a streamed block, a check failing, a tx over
  `:block_stream_max_tx_bytes`) stops the scan there with the reason, and is
  read again next run; it is never skipped. Nothing is recorded for a block
  until every check has passed, so a read cut off mid-block (a deploy, a
  timeout) leaves no row and is simply read again. No third party is asked
  anything.

  `Bitblocks.Workers.SupportScanWorker` runs `run/1` every two minutes on
  its own lane, one block at a time. The time budget is checked between
  blocks, so a GB block, which streams in about as long as the node takes
  to serve it, is always read to its end.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Block, BlockStream, RawBlock}
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
    mark(address, block, :reading)

    result =
      with {:ok, pkh} <- pubkey_hash(address),
           {:ok, gifts} <- gifts_in(block, address, pkh) do
        {:ok, gifts}
      end

    case result do
      {:ok, gifts} ->
        sats = Enum.sum_by(gifts, &elem(&1, 1))

        # Only now, with the block's bytes checked against its header, does
        # anything the read saw count.
        Repo.insert!(
          %BlockScan{
            height: block.height,
            block_hash: block.hash,
            address: address,
            gift_sats: sats,
            gift_txids: Enum.map(gifts, &elem(&1, 0)),
            status: "read",
            error: nil,
            attempts: 0,
            scanned_at: now()
          },
          on_conflict:
            {:replace,
             [:block_hash, :gift_sats, :gift_txids, :status, :error, :attempts, :scanned_at]},
          conflict_target: [:address, :height]
        )

        {:ok, sats}

      {:error, reason} ->
        mark(address, block, {:failed, reason})
        {:error, reason}
    end
  end

  # A row for a block not (yet) read: being read now, or failed, with the
  # reason. It never counts: coverage and gifts read `status: "read"` only.
  defp mark(address, block, state) do
    {status, error} =
      case state do
        :reading -> {"reading", nil}
        {:failed, reason} -> {"failed", inspect(reason)}
      end

    base = %BlockScan{
      height: block.height,
      block_hash: block.hash,
      address: address,
      status: status,
      error: error,
      attempts: if(status == "failed", do: 1, else: 0),
      started_at: if(status == "reading", do: now()),
      scanned_at: now()
    }

    update =
      case status do
        "reading" ->
          [set: [status: "reading", block_hash: block.hash, started_at: now(), scanned_at: now()]]

        "failed" ->
          [
            set: [status: "failed", error: error, block_hash: block.hash, scanned_at: now()],
            inc: [attempts: 1]
          ]
      end

    Repo.insert!(base, on_conflict: update, conflict_target: [:address, :height])
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # `[{txid, sats}]` in block order. A block within the raw cap is fetched
  # whole; a larger one streams through a bounded parser (#66), whose txs are
  # unverified until it returns :ok.
  defp gifts_in(block, address, pkh) do
    if RawBlock.eligible?(block) do
      with {:ok, txs, _stats} <- RawBlock.fetch(block) do
        {:ok,
         for({txid, bytes} <- txs, sats = gift(bytes, address, pkh), sats > 0, do: {txid, sats})}
      end
    else
      collect = fn {txid, bytes}, acc ->
        case gift(bytes, address, pkh) do
          0 -> acc
          sats -> [{txid, sats} | acc]
        end
      end

      with {:ok, gifts, stats} <- BlockStream.each_tx(block, [], collect) do
        Logger.info(
          "support scan: streamed block #{block.height}, #{stats.bytes} bytes, " <>
            "#{stats.txs} txs in #{stats.ms} ms"
        )

        {:ok, Enum.reverse(gifts)}
      end
    end
  end

  # Sats the tx gives `address`, by `Support.Received`'s rule. Most txs pay
  # it nothing, so the inputs are only looked at when an output pays it.
  defp gift(bytes, address, pkh) do
    {inputs, outputs} = RawBlock.tx_io(bytes)

    case for {sats, script} <- outputs, pays?(script, pkh), do: sats do
      [] ->
        0

      paid ->
        # A coinbase input unlocks nothing (RawBlock.tx_json/2 gives it no scriptSig).
        vin =
          for {prev, vout, script} <- inputs,
              not (prev == <<0::256>> and vout == 0xFFFFFFFF),
              do: %{"scriptSig" => %{"hex" => hex(script)}}

        vout =
          for sats <- paid,
              do: %{"value" => sats / 100_000_000, "scriptPubKey" => %{"addresses" => [address]}}

        Received.sats(address, vin, vout)
    end
  end

  # The scripts `RawBlock.script_address/1` reads an address from: P2PKH and
  # P2PK, compared by pubkey hash rather than encoding every output's address.
  defp pays?(<<0x76, 0xA9, 0x14, pkh::binary-20, 0x88, 0xAC>>, pkh), do: true

  defp pays?(<<len, pubkey::binary-size(len), 0xAC>>, pkh) when len in [33, 65],
    do: :crypto.hash(:ripemd160, :crypto.hash(:sha256, pubkey)) == pkh

  defp pays?(_script, _pkh), do: false

  defp pubkey_hash(address) do
    case BSV.Address.from_string(address) do
      {:ok, %{pubkey_hash: pkh}} -> {:ok, pkh}
      _ -> {:error, :invalid_address}
    end
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

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
        where: s.address == ^address and s.height >= ^from and s.status == "read",
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
      where: s.address == ^address and s.height >= ^lo and s.height <= ^hi and s.status == "read",
      select: fragment("coalesce(sum(?), 0)::bigint", s.gift_sats)
    )
    |> Repo.one()
  end

  @doc """
  Why the scan stops after `through`, in a sentence, or nil when it is at
  our tip.
  """
  @spec stop_reason(integer(), String.t() | nil) :: String.t() | nil
  def stop_reason(through, address \\ address()) do
    case Repo.get_by(Block, height: through + 1) do
      nil ->
        nil

      block ->
        scan = address && Repo.get_by(BlockScan, address: address, height: block.height)
        describe(block, scan)
    end
  end

  defp describe(block, %BlockScan{status: "failed", block_hash: hash} = scan)
       when hash == block.hash do
    "Block #{block.height} couldn't be read yet (#{scan.error}; " <>
      "#{scan.attempts} #{if scan.attempts == 1, do: "try", else: "tries"}, last at " <>
      "#{Calendar.strftime(scan.scanned_at, "%H:%M UTC")}); it is tried again every two minutes."
  end

  defp describe(block, %BlockScan{status: "reading", block_hash: hash} = scan)
       when hash == block.hash do
    "Block #{block.height} is being read now, streamed from our node, " <>
      "since #{Calendar.strftime(scan.started_at || scan.scanned_at, "%H:%M UTC")}."
  end

  defp describe(block, _scan) do
    if RawBlock.eligible?(block),
      do: "Block #{block.height} is next to read.",
      else: "Block #{block.height} is next to read, streamed from our node for its size."
  end

  defp config, do: Application.get_env(:bitblocks, :support, [])
end
