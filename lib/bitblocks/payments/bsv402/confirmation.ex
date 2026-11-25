defmodule Bitblocks.Payments.Bsv402.Confirmation do
  @moduledoc """
  Follows each accepted BSV 402 payment until it is settled, dropped or
  conflicted (docs/BSV_402.md, slice 4), asking only our own node about one
  txid at a time and checking its answer against our own headers. Run each
  minute by `Bitblocks.Workers.BsvPaymentWorker`.

  The states of a `bsv_payments` row:

    * `accepted`: our node took it into its mempool; we served the request.
    * `confirmed`: our node puts it in a block, and that block is one our
      headers hold, verified and on the best chain; `block_hash` and
      `block_height` say which. The sync need not have stored the block's
      transactions.
    * `settled`: confirmed, and its block `settle_depth/0` deep (6 by
      default: the block and five on top) by our headers. Final.
    * `dropped`: not in a block `drop_after_hours/0` (24, about 144 blocks)
      after it was accepted, whether our node still holds it in its mempool
      or not. Final; `reason` says which.
    * `conflicted`: our node no longer knows it, and an input it spends is
      spent by another transaction. Final.

  A `confirmed` row whose block our headers no longer hold on the best chain
  (a reorg) goes back to `accepted` and is asked about again at once.
  A `settled` row is not reopened: six blocks is the depth we take as final.

  How our node is asked, cheapest truthful source first:

    1. `getrawtransaction(txid, 1)`: a `blockhash` means mined, none means
       in the mempool;
    2. when the node doesn't know the txid (a node without a full tx index
       knows a mined tx only by its unspent outputs), `gettxoutproof([txid])`:
       the proof's first 80 bytes are the block's header, which names it;
    3. when neither knows it, `gettxout` on each input it spends: one spent
       (or gone) means conflicted. Otherwise it is sent to our node again,
       once (`rebroadcast_at`), and waits for the drop deadline.

  Never WhatsOnChain, and no tip machinery beyond these calls and our headers.

  Bounded: at most `@batch` rows a run, the most overdue first. An
  `accepted` row is asked again after 1, 2, 4, 8 then every 15 minutes
  (`next_check_at`); a `confirmed` row needs no node call (its depth comes
  from our headers) and is looked at each minute. A node that doesn't answer
  leaves the row as it is, for the next check.

  ## The deny list

  A sender key with a payment `dropped` or `conflicted` within the last
  `deny_hours/0` (168, a week) is refused by `Bsv402.verify/3` as `denied`
  (`denied?/2`). The deny list is those rows; nothing else is stored.

  ## Configuration

      config :bitblocks, Bitblocks.Payments.Bsv402,
        settle_depth: 6,
        drop_after_hours: 24,
        deny_hours: 168
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Block, Headers, RawTx}
  alias Bitblocks.Payments.{Bsv402, BsvPayment}
  alias Bitblocks.Repo

  @default_settle_depth 6
  @default_drop_after_hours 24
  @default_deny_hours 168
  @batch 100
  @max_backoff_minutes 15

  @open ~w(accepted confirmed)
  @denying ~w(dropped conflicted)

  @type lookup :: {:mined, String.t()} | :mempool | :unknown | :unavailable

  @doc "Blocks deep, counting its own, at which a confirmed payment is settled."
  @spec settle_depth() :: pos_integer()
  def settle_depth, do: config(:settle_depth, @default_settle_depth)

  @doc "Hours after acceptance at which a payment not yet in a block is dropped."
  @spec drop_after_hours() :: pos_integer()
  def drop_after_hours, do: config(:drop_after_hours, @default_drop_after_hours)

  @doc "Hours a sender is refused after one of its payments is dropped or conflicted."
  @spec deny_hours() :: pos_integer()
  def deny_hours, do: config(:deny_hours, @default_deny_hours)

  @doc "The statuses still followed: `accepted` and `confirmed`."
  @spec open_statuses() :: [String.t()]
  def open_statuses, do: @open

  @doc """
  True when `sender_key` (compressed hex) had a payment dropped or
  conflicted within the last `deny_hours/0`.
  """
  @spec denied?(String.t(), DateTime.t()) :: boolean()
  def denied?(sender_key, now \\ DateTime.utc_now()) when is_binary(sender_key) do
    cutoff = DateTime.add(now, -deny_hours() * 3600, :second)

    Repo.exists?(
      from p in BsvPayment,
        where:
          p.sender_key == ^String.downcase(sender_key) and p.status in @denying and
            p.closed_at > ^cutoff
    )
  end

  @doc "Sender keys refused right now, as a count. For `Release.bsv402_status/0`."
  @spec denied_count(DateTime.t()) :: non_neg_integer()
  def denied_count(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -deny_hours() * 3600, :second)

    Repo.one(
      from p in BsvPayment,
        where: p.status in @denying and p.closed_at > ^cutoff,
        select: count(p.sender_key, :distinct)
    )
  end

  @doc "The oldest payment not yet settled, dropped or conflicted, or nil."
  @spec oldest_open() :: struct() | nil
  def oldest_open do
    Repo.one(
      from p in BsvPayment,
        where: p.status in @open,
        order_by: [asc: p.accepted_at],
        limit: 1,
        select: struct(p, [:txid, :status, :accepted_at, :block_height, :checks])
    )
  end

  @doc """
  Checks every open payment that is due, and returns what moved:
  `%{checked: n, moved: [{txid, from, to}]}`.

  Options, each defaulting to ours, so a test can stub them:

    * `:now`: our clock, a `DateTime`;
    * `:tip`: our headers' tip height (`Sync.tip/0`);
    * `:held`: `fn block_hash -> {:ok, height} | :none end`, whether our
      headers hold that block, verified and on the best chain (`held/1`).

  Our node is reached through the configured `:bitcoinsv_cli`.
  """
  @spec run(keyword()) :: %{checked: non_neg_integer(), moved: [tuple()]}
  def run(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    rows = due(now)

    if rows == [] do
      %{checked: 0, moved: []}
    else
      ctx = %{
        now: now,
        tip: Keyword.get_lazy(opts, :tip, &Bitblocks.Sync.tip/0),
        held: Keyword.get(opts, :held, &held/1)
      }

      moved =
        for row <- rows, {to, _row} = check(row, ctx), to != row.status do
          Logger.info("BSV 402 payment #{row.txid}: #{row.status} -> #{to}")
          {row.txid, row.status, to}
        end

      %{checked: length(rows), moved: moved}
    end
  end

  defp due(now) do
    Repo.all(
      from p in BsvPayment,
        where: p.status in @open and (is_nil(p.next_check_at) or p.next_check_at <= ^now),
        order_by: [asc_nulls_first: p.next_check_at, asc: p.id],
        limit: @batch
    )
  end

  # --- one row ---------------------------------------------------------------------

  defp check(%BsvPayment{status: "confirmed"} = row, ctx) do
    case ctx.held.(row.block_hash) do
      {:ok, height} when height == row.block_height ->
        if depth(ctx.tip, height) >= settle_depth(),
          do: save(row, ctx, "settled", closed_at: ctx.now),
          else: save(row, ctx, "confirmed", next_check_at: minutes(ctx.now, 1))

      _orphaned ->
        # Its block left the best chain: back to waiting, and asked again now.
        {_, row} =
          save(row, ctx, "accepted",
            block_hash: nil,
            block_height: nil,
            confirmed_at: nil,
            checks: 0,
            reason: "its block #{row.block_hash} left the best chain"
          )

        check(row, ctx)
    end
  end

  defp check(%BsvPayment{status: "accepted"} = row, ctx) do
    case lookup(row.txid) do
      {:mined, hash} ->
        case ctx.held.(hash) do
          {:ok, height} -> confirm(row, ctx, hash, height)
          # Our header sync runs a minute behind the node at most.
          :none -> wait(row, ctx)
        end

      :mempool ->
        if overdue?(row, ctx.now),
          do:
            drop(
              row,
              ctx,
              "in our node's mempool, but in no block after #{drop_after_hours()} hours"
            ),
          else: wait(row, ctx)

      :unknown ->
        unknown(row, ctx)

      :unavailable ->
        wait(row, ctx)
    end
  end

  defp confirm(row, ctx, hash, height) do
    if depth(ctx.tip, height) >= settle_depth() do
      save(row, ctx, "settled",
        block_hash: hash,
        block_height: height,
        confirmed_at: row.confirmed_at || ctx.now,
        closed_at: ctx.now
      )
    else
      save(row, ctx, "confirmed",
        block_hash: hash,
        block_height: height,
        confirmed_at: ctx.now,
        next_check_at: minutes(ctx.now, 1)
      )
    end
  end

  # Our node knows the txid neither in its mempool nor in a block.
  defp unknown(row, ctx) do
    case conflict(row.raw_tx) do
      {:conflicted, outpoint} ->
        conflict!(row, ctx, "our node no longer knows it, and its input #{outpoint} is spent")

      :unavailable ->
        wait(row, ctx)

      :none ->
        cond do
          overdue?(row, ctx.now) ->
            drop(
              row,
              ctx,
              "not in our node's mempool or in a block after #{drop_after_hours()} hours"
            )

          is_nil(row.rebroadcast_at) ->
            rebroadcast(row, ctx)

          true ->
            wait(row, ctx)
        end
    end
  end

  defp rebroadcast(row, ctx) do
    case Bsv402.broadcast(row.raw_tx) do
      answer when answer in [:accepted, :already_known] ->
        wait(row, ctx, rebroadcast_at: ctx.now, reason: "sent to our node again")

      {:rejected, message} ->
        wait(row, ctx, rebroadcast_at: ctx.now, reason: "sent again, refused: #{message}")

      :unavailable ->
        wait(row, ctx)
    end
  end

  defp drop(row, ctx, reason), do: save(row, ctx, "dropped", reason: reason, closed_at: ctx.now)

  defp conflict!(row, ctx, reason),
    do: save(row, ctx, "conflicted", reason: reason, closed_at: ctx.now)

  defp wait(row, ctx, changes \\ []) do
    backoff = min(Integer.pow(2, min(row.checks, 4)), @max_backoff_minutes)

    save(row, ctx, row.status, Keyword.merge([next_check_at: minutes(ctx.now, backoff)], changes))
  end

  defp save(row, ctx, status, changes) do
    changes =
      Keyword.merge(
        [status: status, checked_at: ctx.now, checks: row.checks + 1, updated_at: ctx.now],
        changes
      )

    {1, _} = Repo.update_all(from(p in BsvPayment, where: p.id == ^row.id), set: changes)
    {status, struct(row, changes)}
  end

  defp overdue?(row, now),
    do: DateTime.diff(now, row.accepted_at, :second) >= drop_after_hours() * 3600

  defp depth(tip, height) when is_integer(tip) and is_integer(height), do: tip - height + 1
  defp depth(_tip, _height), do: 0

  defp minutes(now, n), do: DateTime.add(now, n * 60, :second)

  # --- our node ----------------------------------------------------------------------

  @doc """
  Where our node puts `txid`: `{:mined, block_hash}`, `:mempool`, `:unknown`
  (neither), or `:unavailable` when it didn't answer.
  """
  @spec lookup(String.t()) :: lookup()
  def lookup(txid) do
    case rpc().getrawtransaction(txid, 1) do
      %{"blockhash" => hash} when is_binary(hash) and hash != "" ->
        {:mined, String.downcase(hash)}

      %{"txid" => _} ->
        :mempool

      {:error, %{"code" => -5}} ->
        proof_block(txid)

      _ ->
        :unavailable
    end
  end

  # A node without a full tx index still proves a mined tx with an unspent
  # output; the proof opens with the block's 80-byte header.
  defp proof_block(txid) do
    case rpc().gettxoutproof([txid]) do
      hex when is_binary(hex) ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, <<header::binary-80, _::binary>>} -> {:mined, block_hash(header)}
          _ -> :unavailable
        end

      {:error, %{"code" => -5}} ->
        :unknown

      _ ->
        :unavailable
    end
  end

  defp block_hash(header) do
    :crypto.hash(:sha256, :crypto.hash(:sha256, header))
    |> reverse()
    |> Base.encode16(case: :lower)
  end

  defp reverse(bytes),
    do: bytes |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  # Each input's previous output, asked of our node with its mempool: one
  # gone means another transaction spent it.
  defp conflict(raw) do
    case RawTx.flows(Base.encode16(raw, case: :lower)) do
      {:ok, %{inputs: inputs}} ->
        inputs
        |> Enum.reject(&(&1 == :coinbase))
        |> Enum.reduce_while(:none, fn {txid, vout}, :none ->
          case rpc().gettxout(txid, vout, true) do
            nil -> {:halt, {:conflicted, "#{txid}:#{vout}"}}
            %{} -> {:cont, :none}
            _ -> {:halt, :unavailable}
          end
        end)

      _ ->
        :unavailable
    end
  end

  # --- our headers ------------------------------------------------------------------

  @doc """
  `{:ok, height}` when our headers hold the block `hash`, verified and on the
  best chain (`Chain.Headers`); `:none` otherwise.
  """
  @spec held(String.t() | nil) :: {:ok, non_neg_integer()} | :none
  def held(hash) when is_binary(hash) do
    hash = String.downcase(hash)

    with height when is_integer(height) <-
           Repo.one(from b in Block, where: b.hash == ^hash, select: b.height),
         %{hash: ^hash, verified: true, canonical: true} <- Headers.at(height) do
      {:ok, height}
    else
      _ -> :none
    end
  end

  def held(_hash), do: :none

  defp rpc, do: Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)

  defp config(key, default) do
    case :bitblocks |> Application.get_env(Bsv402, []) |> Keyword.get(key) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end
end
