defmodule Bitblocks.Repo do
  use Ecto.Repo,
    otp_app: :bitblocks,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Runs `fun` in a transaction whose `statement_timeout` is `timeout_ms`, for
  reads a page waits on.

  Postgres cancels any statement past the timeout, a lock wait included, and
  the call as a whole (queueing for a connection too) is capped a little
  above it, so a slow read frees its connection in seconds.
  `{:ok, result}`, or `{:error, :timeout}` for a cancelled statement or a
  connection not had in time, `{:error, :unavailable}` for any other
  database error.
  """
  @spec with_statement_timeout(pos_integer(), (-> term())) ::
          {:ok, term()} | {:error, :timeout | :unavailable}
  def with_statement_timeout(timeout_ms, fun)
      when is_integer(timeout_ms) and timeout_ms > 0 and is_function(fun, 0) do
    transaction(
      fn ->
        query!("SET LOCAL statement_timeout = #{timeout_ms}")
        result = fun.()
        # Inside an outer transaction (a test's sandbox) this is a savepoint,
        # and SET LOCAL would outlive it; put the default back.
        query!("SET LOCAL statement_timeout TO DEFAULT")
        result
      end,
      timeout: timeout_ms + 2_000
    )
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: :query_canceled}} -> {:error, :timeout}
        _ -> {:error, :unavailable}
      end

    error in DBConnection.ConnectionError ->
      if error.message =~ "timed out", do: {:error, :timeout}, else: {:error, :unavailable}
  end
end
