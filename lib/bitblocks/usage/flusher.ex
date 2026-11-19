defmodule Bitblocks.Usage.Flusher do
  @moduledoc """
  Owns the usage counters' ETS table (`Bitblocks.Usage`) and moves them into
  `usage_rollups` every `:usage_flush_ms` (60 s; nil turns the timer off, as
  the test config does), and once more on shutdown. Runs on every node,
  readers too: each meters its own requests.
  """
  use GenServer
  require Logger

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Bitblocks.Usage.create_table()
    Bitblocks.Usage.attach()
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:flush, state) do
    flush()
    schedule()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: flush()

  defp flush do
    case Bitblocks.Usage.flush() do
      {:ok, _rows} -> :ok
      {:error, reason} -> Logger.warning("Usage flush failed, kept for the next one: #{reason}")
    end
  end

  defp schedule do
    case Application.get_env(:bitblocks, :usage_flush_ms, 60_000) do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :flush, ms)
      _ -> :ok
    end
  end
end
