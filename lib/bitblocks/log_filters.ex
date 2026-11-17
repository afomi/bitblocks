defmodule Bitblocks.LogFilters do
  @moduledoc """
  `:logger` filters installed at boot (`Bitblocks.Application`).

  Bandit logs every request it can't parse at error level, so a scanner
  sending garbage request lines shows up in the error digest as a new kind
  of app error though nothing failed
  (https://github.com/afomi/bitblocks/issues/90, ported from
  https://github.com/afomi/commons/issues/98).
  `malformed_request/2` lowers those to warning; every other event, including
  real errors from the app and other Bandit errors, passes through unchanged.
  """

  # Messages Bandit raises when a client's request line or headers can't be
  # parsed (deps/bandit/lib/bandit/http1/socket.ex). Timeouts and body errors
  # are left at error.
  @malformed_prefixes [
    "Request line ",
    "Request URI is too long",
    "Invalid HTTP version",
    "Unsupported request target",
    "Header read ",
    "Header too long",
    "Too many headers",
    "Header contains invalid port",
    "Unable to obtain host and port"
  ]

  @doc "Installs the filters as primary `:logger` filters. Safe to call twice."
  def install do
    case :logger.add_primary_filter(:malformed_request, {&__MODULE__.malformed_request/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
    end
  end

  @doc """
  A `:logger` filter: an error-level `Bandit.HTTPError` for a malformed
  request comes back as a warning; anything else is `:ignore` (unchanged).
  """
  def malformed_request(
        %{level: :error, meta: %{crash_reason: {%Bandit.HTTPError{message: message}, _}}} = event,
        _extra
      )
      when is_binary(message) do
    if String.starts_with?(message, @malformed_prefixes),
      do: %{event | level: :warning},
      else: :ignore
  end

  def malformed_request(_event, _extra), do: :ignore
end
