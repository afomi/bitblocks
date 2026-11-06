defmodule Bitblocks.Ops.ErrorLog do
  @moduledoc """
  The most recent error log lines, kept in memory for `Ops.errors/1` (#50).

  A `:logger` handler at level `:error`. Each line is scrubbed
  (`Bitblocks.Ops.Scrub`) before it is stored, so a secret in a message never
  sits in the table, and only the level, the time and the message are kept:
  log metadata carries caller IPs and user agents.

  The last 200 lines on this node, gone on restart. A handler runs in the
  process that logged, so this one must never raise: logger would drop it.
  """

  alias Bitblocks.Ops.Scrub

  @table :ops_error_log
  @handler :bitblocks_ops_error_log
  @capacity 200

  @doc "How many lines are kept."
  def capacity, do: @capacity

  @doc "Creates the table and attaches the handler. Called once at boot."
  def attach do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:ordered_set, :public, :named_table, write_concurrency: true])
    end

    case :logger.add_handler(@handler, __MODULE__, %{level: :error}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      error -> error
    end
  end

  @doc "Up to `limit` lines, newest first."
  @spec recent(pos_integer()) :: [%{at: String.t(), level: String.t(), message: String.t()}]
  def recent(limit) do
    case :ets.whereis(@table) do
      :undefined -> []
      _ -> @table |> :ets.tab2list() |> Enum.reverse() |> Enum.take(limit) |> Enum.map(&entry/1)
    end
  end

  @doc false
  # :logger handler callback.
  def log(%{level: level, msg: msg} = event, _config) do
    time = event |> Map.get(:meta, %{}) |> Map.get(:time, System.system_time(:microsecond))
    :ets.insert(@table, {{time, :erlang.unique_integer()}, level, Scrub.line(text(msg))})

    if :ets.info(@table, :size) > @capacity, do: :ets.delete(@table, :ets.first(@table))
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp entry({{time, _}, level, message}) do
    at = time |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
    %{at: at, level: to_string(level), message: message}
  end

  defp text({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp text({:report, report}), do: report
  defp text({format, args}), do: format |> :io_lib.format(args) |> IO.chardata_to_string()
end
