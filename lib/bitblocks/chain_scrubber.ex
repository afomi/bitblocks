defmodule Bitblocks.ChainScrubber do
  @moduledoc """
  What the scrubber shows when it rests on a block, and what it annotates.

  Scrubbing itself reads tiles (`Bitblocks.ChainTiles`), never the database.
  `rest/2` is the one tx-level read: a block's row by height (unique index),
  then at most `cap` transactions by `block_hash` (indexed) under a
  `statement_timeout`. `transactions` is tens of GB and its planner stats go
  stale, so a read that would hang instead fails to an explicit
  `unavailable` payload. A block that is not `completed` answers as a gap.

  Above the threshold the block is drawn as a density field, not marks:
  a fixed 16 x 64 grid of tx class (coinbase, plain transfer, one row per
  protocol) by log2 of output value, counted over the capped sample, so a
  four-million-tx block costs the same to draw as a forty-thousand one.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.ChainScrubber.Losses
  alias Bitblocks.Reorgs
  alias Bitblocks.Repo

  @default_cap 2_000
  @default_threshold 10_000
  @default_timeout_ms 2_000
  @grid_rows 16
  @grid_cols 64

  def default_cap, do: @default_cap
  def default_threshold, do: @default_threshold
  def default_timeout_ms, do: @default_timeout_ms
  def grid_rows, do: @grid_rows
  def grid_cols, do: @grid_cols

  @doc """
  The payload for resting on `height`. Options: `cap:` (max txs read,
  default #{@default_cap}), `threshold:` (num_tx above which the answer is a
  density grid, default #{@default_threshold}), `timeout_ms:` (statement
  timeout, default #{@default_timeout_ms}).

  Kinds: `missing` (no row), `gap` (not completed), `marks`, `density`,
  `unavailable`.
  """
  @spec rest(non_neg_integer(), keyword()) :: map()
  def rest(height, opts \\ []) when is_integer(height) and height >= 0 do
    cap = Keyword.get(opts, :cap, @default_cap)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case block_row(height) do
      nil ->
        %{kind: "missing", height: height}

      %{sync_state: state} = block when state != "completed" ->
        Map.merge(block, %{kind: "gap", state: state})

      block ->
        dense? = (block.num_tx || 0) > threshold

        case sample_transactions(block.hash, cap, timeout_ms) do
          {:ok, txs} when dense? ->
            Map.merge(block, density(txs))

          {:ok, txs} ->
            Map.merge(block, marks(txs))

          {:error, reason} ->
            Map.merge(block, %{kind: "unavailable", reason: Atom.to_string(reason)})
        end
    end
  end

  defp block_row(height) do
    Repo.one(
      from(b in Block,
        where: b.height == ^height,
        select: %{
          height: b.height,
          hash: b.hash,
          time: b.time,
          size: b.size,
          num_tx: b.num_tx,
          sync_state: b.sync_state
        }
      )
    )
  end

  @doc """
  At most `cap` transactions of a block, under a statement timeout.
  `{:error, :timeout}` when Postgres cancelled the read; `{:error,
  :unavailable}` on any other database failure. Never hangs past the timeout.
  """
  @spec sample_transactions(String.t(), pos_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, :timeout | :unavailable}
  def sample_transactions(block_hash, cap, timeout_ms)
      when is_integer(cap) and cap > 0 and is_integer(timeout_ms) and timeout_ms > 0 do
    query =
      from(t in Transaction,
        where: t.block_hash == ^block_hash,
        limit: ^cap,
        select: %{
          txid: t.txid,
          coinbase: t.coinbase,
          protocols: t.protocols,
          sats: t.total_output_satoshis,
          inputs: t.input_count,
          outputs: t.output_count
        }
      )

    with_statement_timeout(timeout_ms, fn -> Repo.all(query) end)
  end

  @doc """
  Runs `fun` in a transaction whose `statement_timeout` is `timeout_ms`.
  A cancelled statement is `{:error, :timeout}`; any other database error is
  `{:error, :unavailable}`.
  """
  @spec with_statement_timeout(pos_integer(), (-> term())) ::
          {:ok, term()} | {:error, :timeout | :unavailable}
  def with_statement_timeout(timeout_ms, fun) when is_integer(timeout_ms) and timeout_ms > 0 do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL statement_timeout = #{timeout_ms}")
      fun.()
    end)
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: :query_canceled}} -> {:error, :timeout}
        _ -> {:error, :unavailable}
      end

    _error in DBConnection.ConnectionError ->
      {:error, :unavailable}
  end

  # -- Block level -------------------------------------------------------------

  defp marks(txs) do
    %{
      kind: "marks",
      sample: length(txs),
      txs:
        Enum.map(txs, fn tx ->
          %{
            txid: tx.txid,
            sats: tx.sats || 0,
            inputs: tx.inputs || 0,
            outputs: tx.outputs || 0,
            coinbase: tx.coinbase == true,
            protocols: tx.protocols || []
          }
        end)
    }
  end

  @doc """
  The density grid for a sample: `rows` names (`coinbase`, `transfer`, the
  most frequent protocols, `other`), `cols` = #{@grid_cols} log2 value bins,
  and `grid`, a flat row-major list of #{@grid_rows * @grid_cols} counts.
  Its size never depends on the sample.
  """
  @spec density([map()]) :: map()
  def density(txs) do
    protocol_rows =
      txs
      |> Enum.reject(&(&1.coinbase == true))
      |> Enum.flat_map(&(&1.protocols || []))
      |> Enum.frequencies()
      |> Enum.sort_by(fn {name, n} -> {-n, name} end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.take(@grid_rows - 3)

    rows = ["coinbase", "transfer"] ++ protocol_rows ++ ["other"]
    rows = rows ++ List.duplicate("", @grid_rows - length(rows))
    row_index = rows |> Enum.with_index() |> Map.new()

    counts =
      Enum.reduce(txs, %{}, fn tx, acc ->
        row = row_for(tx, row_index)
        col = value_bin(tx.sats)
        Map.update(acc, row * @grid_cols + col, 1, &(&1 + 1))
      end)

    grid = for cell <- 0..(@grid_rows * @grid_cols - 1), do: Map.get(counts, cell, 0)

    %{kind: "density", sample: length(txs), rows: rows, cols: @grid_cols, grid: grid}
  end

  defp row_for(%{coinbase: true}, _rows), do: 0
  defp row_for(%{protocols: protocols}, _rows) when protocols in [nil, []], do: 1

  defp row_for(%{protocols: [first | _]}, rows), do: Map.get(rows, first, @grid_rows - 1)

  @doc "The log2 bin of an output value, 0..#{@grid_cols - 1}."
  @spec value_bin(integer() | nil) :: non_neg_integer()
  def value_bin(sats) when is_nil(sats) or sats <= 0, do: 0
  def value_bin(sats), do: sats |> :math.log2() |> floor() |> min(@grid_cols - 1)

  # -- Annotations -------------------------------------------------------------

  @doc """
  Marks for what the chain doesn't announce: recorded reorgs and classified
  losses, each with the height it happened at and a link to its evidence.
  """
  @spec annotations() :: [map()]
  def annotations do
    reorgs =
      Enum.map(Reorgs.list_reorgs(), fn r ->
        %{
          kind: "reorg",
          height: r.fork_height,
          label: "Reorg at #{r.fork_height} (#{r.outcome})",
          detail: r.summary,
          evidence_url: "/reorgs"
        }
      end)

    losses =
      Enum.map(Losses.classified(), fn l ->
        %{
          kind: "loss",
          height: l.height,
          label: "#{l.item} #{l.kind} at #{l.height}",
          detail: "#{l.item} spent outside Run in #{l.spender} on #{l.date}. #{l.note}",
          evidence_url: "/transactions/#{l.spender}",
          note_url: l.note_url
        }
      end)

    Enum.sort_by(reorgs ++ losses, & &1.height)
  end
end
