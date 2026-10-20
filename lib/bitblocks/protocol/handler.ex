defmodule Bitblocks.Protocol.Handler do
  @moduledoc """
  The behaviour every on-chain protocol handler implements — one module per
  protocol, registered (in detection order) in `Bitblocks.Protocol.Handlers`.

  Adding a protocol used to mean editing detection tables in
  `TransactionParser`, a dispatch clause in `ProtocolParser`, and registry
  seeds — three sites that could drift. Now it's one module + one registry
  entry.

  ## Detection

  Two complementary mechanisms; a handler may use either or both:

    * `segment_matcher/0` — declarative match on the FIRST chunk of a piped
      OP_RETURN segment (`{:prefix, addr}` for Bitcom addresses, `{:exact, s}`
      or `{:contains, s}` for magic strings). The registry walks segments in
      order and takes the first matching handler per segment, which preserves
      the historical detection ordering exactly.

    * `detect/1` — a predicate over the whole `Bitblocks.Protocol.Context`
      for protocols identified by something other than a segment prefix
      (MAP `app=` values, hex sniffs, joined-text formats like vCard).

  ## Deep parsing

  `parse/1` (optional) takes the parsed OP_RETURN chunk maps and returns the
  protocol's structured record — `ProtocolParser.build_protocol_data/2`
  dispatches here by name.

  ## Declarative usage

      defmodule Bitblocks.Protocol.Handlers.B do
        use Bitblocks.Protocol.Handler,
          name: "B://",
          prefix: "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"
      end
  """

  alias Bitblocks.Protocol.Context

  @callback name() :: String.t()
  @callback segment_matcher() :: {:prefix | :exact | :contains, String.t()} | nil
  @callback detect(Context.t()) :: boolean()
  @callback parse(list()) :: {:ok, map()} | {:error, term()}
  @optional_callbacks parse: 1

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Bitblocks.Protocol.Handler

      @handler_name Keyword.fetch!(opts, :name)

      @segment_matcher (cond do
                          prefix = Keyword.get(opts, :prefix) -> {:prefix, prefix}
                          exact = Keyword.get(opts, :exact) -> {:exact, exact}
                          contains = Keyword.get(opts, :contains) -> {:contains, contains}
                          true -> nil
                        end)

      @impl true
      def name, do: @handler_name

      @impl true
      def segment_matcher, do: @segment_matcher

      @impl true
      def detect(_context), do: false

      defoverridable detect: 1, segment_matcher: 0
    end
  end

  @doc """
  True when `first_chunk` (a segment's first utf8 chunk) satisfies a matcher.
  """
  def segment_match?({:prefix, prefix}, first_chunk), do: String.starts_with?(first_chunk, prefix)
  def segment_match?({:exact, value}, first_chunk), do: first_chunk == value
  def segment_match?({:contains, value}, first_chunk), do: String.contains?(first_chunk, value)
  def segment_match?(nil, _first_chunk), do: false
end
