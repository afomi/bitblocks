defmodule Bitblocks.Protocol.Handlers do
  @moduledoc """
  The ordered, compile-time protocol handler registry.

  Compile-time (a module attribute, not the DB) because detection runs on
  every transaction during sync — no DB round-trips on the hot path. The DB
  `ProtocolRegistry` remains the metadata/stats/display layer, keyed by the
  same names.

  ## Order matters

  `detect_all/1` reproduces the historical detection semantics exactly:

  1. Walk each piped segment in order; the FIRST handler (in registry order)
     whose `segment_matcher/0` matches the segment's first chunk names that
     segment's protocol. Registry order therefore encodes the old
     address-table-then-magic-strings precedence — e.g. `"orderbook"` must hit
     `OrderBook` (`:exact`) before `Ordinals` (`:prefix "ord"`).
  2. Segments that matched NO compile-time handler are then checked against
     `Bitblocks.Protocol.RegistryCache` — DB-registered prefix-only protocols
     (ETS lookup only; empty cache means this step is a no-op).
  3. Then every handler's `detect/1` predicate runs over the whole context
     (MAP `app=` values, hex sniffs, vCard text), in registry order.

  Adding a protocol = one handler module + one entry here — or, for a
  prefix-only protocol, just a `ProtocolRegistry` DB row + cache refresh.
  """

  alias Bitblocks.Protocol.{Context, Handler, RegistryCache}
  alias Bitblocks.Protocol.Handlers, as: H

  @handlers [
    H.B,
    H.Map,
    H.Aip,
    H.Haip,
    H.Twetch,
    H.RelayX,
    H.BCat,
    H.Metanet,
    H.OrderBook,
    H.Ordinals,
    H.Bitcom,
    H.Run,
    H.VCard,
    H.Bsv20
  ]

  @doc "Every registered handler, in detection order."
  def all, do: @handlers

  @doc "Every registered protocol name, in detection order."
  def names, do: Enum.map(@handlers, & &1.name())

  @doc "The handler registered under `name`, or nil."
  def get(name), do: Enum.find(@handlers, &(&1.name() == name))

  @doc """
  Detects every protocol present in one OP_RETURN output's parsed chunk maps.

  Returns protocol names, deduplicated: compile-time segment matches first
  (in segment order), then DB-registered prefix matches from `RegistryCache`
  for segments no compile-time handler claimed (in segment order), then
  context-predicate matches (in registry order). With an empty cache the
  result is identical to compile-time-only detection.
  """
  def detect_all(data_chunks) when is_list(data_chunks) do
    context = Context.build(data_chunks)

    {segment_names, unmatched_firsts} =
      Enum.reduce(context.segments, {[], []}, fn segment, {names, unmatched} ->
        case List.first(segment) do
          nil ->
            {names, unmatched}

          first ->
            case segment_match(first) do
              nil -> {names, [first | unmatched]}
              name -> {[name | names], unmatched}
            end
        end
      end)

    segment_names = Enum.reverse(segment_names)

    registry_names =
      unmatched_firsts
      |> Enum.reverse()
      |> Enum.flat_map(&List.wrap(RegistryCache.match_name(&1)))

    context_names = for handler <- @handlers, handler.detect(context), do: handler.name()

    Enum.uniq(segment_names ++ registry_names ++ context_names)
  end

  @doc """
  Deep-parses `data_chunks` as `protocol_name` via its handler's `parse/1`.

  `{:error, :unsupported_protocol}` when no handler is registered under that
  name or the handler has no deep parser.
  """
  def parse(data_chunks, protocol_name) do
    with handler when handler != nil <- get(protocol_name),
         {:module, _} <- Code.ensure_loaded(handler),
         true <- function_exported?(handler, :parse, 1) do
      handler.parse(data_chunks)
    else
      _ -> {:error, :unsupported_protocol}
    end
  end

  defp segment_match(first_chunk) do
    Enum.find_value(@handlers, fn handler ->
      if Handler.segment_match?(handler.segment_matcher(), first_chunk), do: handler.name()
    end)
  end
end
