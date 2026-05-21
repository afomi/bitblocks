defmodule Bitblocks.MemoryMonitor do
  @moduledoc """
  Monitors memory usage and logs warnings when approaching limits.

  Helps identify memory leaks and processes consuming excessive memory.
  """
  use GenServer
  require Logger

  @check_interval :timer.seconds(30)
  @warning_threshold_mb 3000
  @critical_threshold_mb 3600

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{last_check: DateTime.utc_now(), high_memory_warnings: 0}}
  end

  @impl true
  def handle_info(:check_memory, state) do
    memory_info = get_memory_info()
    total_mb = bytes_to_mb(memory_info.total)

    # Log current usage
    Logger.info("Memory usage: #{total_mb} MB (#{memory_info.processes_count} processes)")

    # Check thresholds
    cond do
      total_mb >= @critical_threshold_mb ->
        Logger.error("""
        CRITICAL: Memory usage at #{total_mb} MB (#{percentage(total_mb, 4096)}% of 4GB limit)

        Top memory consumers:
        #{format_top_processes(10)}

        ETS tables:
        #{format_ets_tables()}

        System:
        - Processes: #{memory_info.processes_count}
        - Atom count: #{memory_info.atom_count}
        - Binary memory: #{bytes_to_mb(memory_info.binary)} MB
        """)

        # Emit critical telemetry
        :telemetry.execute(
          [:bitblocks, :memory, :critical],
          %{total_mb: total_mb, processes: memory_info.processes_count},
          %{}
        )

        schedule_check()
        {:noreply, %{state | high_memory_warnings: state.high_memory_warnings + 1}}

      total_mb >= @warning_threshold_mb ->
        Logger.warning("""
        WARNING: Memory usage at #{total_mb} MB (#{percentage(total_mb, 2048)}% of 2GB limit)

        Top 5 memory consumers:
        #{format_top_processes(5)}
        """)

        :telemetry.execute(
          [:bitblocks, :memory, :warning],
          %{total_mb: total_mb, processes: memory_info.processes_count},
          %{}
        )

        schedule_check()
        {:noreply, %{state | high_memory_warnings: state.high_memory_warnings + 1}}

      true ->
        # Normal usage
        :telemetry.execute(
          [:bitblocks, :memory, :check],
          %{total_mb: total_mb, processes: memory_info.processes_count},
          %{}
        )

        schedule_check()
        {:noreply, %{state | last_check: DateTime.utc_now()}}
    end
  end

  ## Public API

  @doc """
  Gets current memory information.
  """
  def get_memory_info do
    memory = :erlang.memory()

    %{
      total: Keyword.get(memory, :total),
      processes: Keyword.get(memory, :processes),
      system: Keyword.get(memory, :system),
      atom: Keyword.get(memory, :atom),
      binary: Keyword.get(memory, :binary),
      ets: Keyword.get(memory, :ets),
      processes_count: :erlang.system_info(:process_count),
      atom_count: :erlang.system_info(:atom_count)
    }
  end

  @doc """
  Gets the top N processes by memory usage.
  """
  def top_processes(n \\ 10) do
    Process.list()
    |> Enum.map(fn pid ->
      case Process.info(pid, [:memory, :registered_name, :current_function, :message_queue_len]) do
        nil ->
          nil

        info ->
          %{
            pid: pid,
            memory: Keyword.get(info, :memory, 0),
            name: Keyword.get(info, :registered_name),
            function: Keyword.get(info, :current_function),
            queue_len: Keyword.get(info, :message_queue_len, 0)
          }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.memory, :desc)
    |> Enum.take(n)
  end

  @doc """
  Gets information about all ETS tables and their memory usage.
  """
  def ets_tables do
    :ets.all()
    |> Enum.map(fn table ->
      info = :ets.info(table)

      %{
        name: Keyword.get(info, :name),
        size: Keyword.get(info, :size, 0),
        memory: Keyword.get(info, :memory, 0),
        type: Keyword.get(info, :type),
        owner: Keyword.get(info, :owner)
      }
    end)
    |> Enum.sort_by(& &1.memory, :desc)
  end

  @doc """
  Forces garbage collection on all processes.

  Use with caution - this will pause all processes briefly.
  """
  def force_global_gc do
    Logger.warning("Forcing global garbage collection")
    before_mb = bytes_to_mb(:erlang.memory(:total))
    start_time = System.monotonic_time()

    count =
      Process.list()
      |> Enum.map(fn pid ->
        try do
          :erlang.garbage_collect(pid)
          1
        catch
          _, _ -> 0
        end
      end)
      |> Enum.sum()

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    Logger.info("Garbage collected #{count} processes in #{duration_ms}ms")

    after_mb = bytes_to_mb(:erlang.memory(:total))

    Logger.info(
      "Memory before: #{before_mb} MB, after: #{after_mb} MB, freed: #{before_mb - after_mb} MB"
    )

    :ok
  end

  ## Private Functions

  defp schedule_check do
    Process.send_after(self(), :check_memory, @check_interval)
  end

  defp bytes_to_mb(bytes) when is_integer(bytes) do
    Float.round(bytes / 1_024 / 1_024, 2)
  end

  defp percentage(value, total) do
    Float.round(value / total * 100, 1)
  end

  defp format_top_processes(n) do
    top_processes(n)
    |> Enum.map(fn proc ->
      name = proc.name || inspect(proc.pid)
      mb = bytes_to_mb(proc.memory)
      queue = if proc.queue_len > 0, do: " [queue: #{proc.queue_len}]", else: ""

      "  - #{name}: #{mb} MB#{queue}"
    end)
    |> Enum.join("\n")
  end

  defp format_ets_tables do
    ets_tables()
    |> Enum.take(5)
    |> Enum.map(fn table ->
      mb = bytes_to_mb(table.memory * :erlang.system_info(:wordsize))
      "  - #{table.name}: #{mb} MB (#{table.size} entries)"
    end)
    |> Enum.join("\n")
  end
end
