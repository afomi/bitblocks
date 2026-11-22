defmodule Bitblocks.Sync.Position do
  @moduledoc """
  Our tip and `complete_through`, for a page request, from memory.

  `Sync.tip/0` and `Sync.complete_through/1` are a `max(height)` and a
  `count(*) FROM blocks WHERE height < $1` (250–900 ms on production). Every
  spent-ness read ran both (`Chain.Utxos.coverage/0`), so a crawl of
  transaction pages put them in the pool's queue thousands of times a
  minute for the same two numbers.

  Here they come from the shared sync snapshot (`Bitblocks.SyncProgress`, an
  ETS read): the coordinator's broadcast (every few seconds on the leader)
  or the snapshot's own reload (every 30 seconds). A snapshot older than
  `@max_age_s`, or none yet (at boot, or a node with no snapshot), falls
  back to the database at most once per `:ttl_ms` (5 seconds), shared by
  every request on the node.

  The trade-off: a page's "unspent" can lag the sync by that interval. A
  block stored since the snapshot may spend an output the page still calls
  unspent, and a rewind may lower `complete_through` under a page that has
  not seen it yet. `position(fresh: true)` reads the database every time,
  for a caller that needs the stricter answer, and
  `config :bitblocks, #{inspect(__MODULE__)}, source: :database` makes that
  the default for every caller (the tests run that way).
  """

  require Logger

  alias Bitblocks.{Sync, SyncProgress}

  @type t :: %{tip: integer() | nil, complete_through: integer()}

  # The snapshot publishes at least every 30 s while its reload works.
  @max_age_s 120
  @default_ttl_ms 5_000
  @table Bitblocks.SyncProgress
  @key {__MODULE__, :position}
  @lock {__MODULE__, :refreshing}
  @lock_ms 30_000

  @doc """
  `%{tip, complete_through}`. From the snapshot unless it is stale, else
  from a short-lived copy of the database's answer. `fresh: true` asks the
  database.
  """
  @spec position(keyword()) :: t()
  def position(opts \\ []) do
    if Keyword.get(opts, :fresh, config(:source, :memory) == :database) do
      from_database()
    else
      case from_snapshot(SyncProgress.snapshot()) do
        {:ok, position} -> position
        :none -> cached()
      end
    end
  end

  @doc "Our highest stored header, as `position/1` reads it."
  @spec tip(keyword()) :: integer() | nil
  def tip(opts \\ []), do: position(opts).tip

  @doc "`complete_through`, as `position/1` reads it."
  @spec complete_through(keyword()) :: integer()
  def complete_through(opts \\ []), do: position(opts).complete_through

  @doc false
  # The coordinator's overview is the freshest; the snapshot's own reload
  # is the fallback. Either needs both numbers and a recent publish.
  def from_snapshot(%{updated_at: %DateTime{} = at} = snapshot) do
    fresh? = DateTime.diff(DateTime.utc_now(), at, :second) <= @max_age_s

    case {fresh?, snapshot[:sync], snapshot[:overview]} do
      {false, _, _} ->
        :none

      {true, %{tip: tip, complete_through: through}, _}
      when is_integer(tip) and is_integer(through) ->
        {:ok, %{tip: tip, complete_through: through}}

      {true, _, %{our_tip: tip, complete_through: through}}
      when is_integer(tip) and is_integer(through) ->
        {:ok, %{tip: tip, complete_through: through}}

      _ ->
        :none
    end
  end

  def from_snapshot(_snapshot), do: :none

  # One request per node refreshes at a time; the rest keep the last
  # answer meanwhile. With no answer yet, a request asks for itself.
  defp cached do
    now = System.monotonic_time(:millisecond)
    ttl = ttl_ms()

    case lookup() do
      {position, at} when now - at < ttl ->
        position

      {position, _stale_at} ->
        if take_lock(), do: locked_refresh(now), else: position

      nil ->
        refresh(now)
    end
  end

  defp locked_refresh(now) do
    refresh(now)
  after
    release_lock()
  end

  defp refresh(now) do
    position = from_database()
    store(position, now)
    position
  end

  defp from_database do
    tip = Sync.tip()
    %{tip: tip, complete_through: Sync.complete_through(tip)}
  end

  defp lookup do
    case :ets.lookup(@table, @key) do
      [{@key, position, at}] -> {position, at}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp store(position, now) do
    :ets.insert(@table, {@key, position, now})
  rescue
    ArgumentError -> :ok
  end

  # A lock older than @lock_ms belonged to a request that died mid-read.
  defp take_lock do
    now = System.monotonic_time(:millisecond)

    :ets.insert_new(@table, {@lock, now}) or
      case :ets.lookup(@table, @lock) do
        [{@lock, at}] when now - at > @lock_ms ->
          :ets.insert(@table, {@lock, now})

        _ ->
          false
      end
  rescue
    ArgumentError -> true
  end

  defp release_lock do
    :ets.delete(@table, @lock)
  rescue
    ArgumentError -> :ok
  end

  @doc false
  # Forgets the database copy (tests).
  def reset do
    :ets.delete(@table, @key)
    :ets.delete(@table, @lock)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ttl_ms, do: config(:ttl_ms, @default_ttl_ms)

  defp config(key, default) do
    :bitblocks |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
