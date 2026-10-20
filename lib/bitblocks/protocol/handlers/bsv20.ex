defmodule Bitblocks.Protocol.Handlers.Bsv20 do
  @moduledoc """
  BSV-20 / BSV-21 tokens.

  Unlike every other handler, tokens live as ordinal inscriptions in output
  *locking* scripts — not OP_RETURN push data — so context-level `detect/1` is
  never true here. Detection happens per-output in
  `TransactionParser.analyze/1` via `Bsv20Parser.token_inscription?/1`, and
  deep parsing goes through `ProtocolParser.parse_raw(raw, "BSV20")` /
  `token_outputs/1`, which need the full raw transaction.

  Registered so "BSV20" resolves in the handler registry (name enumeration,
  future index/2 wiring).
  """

  use Bitblocks.Protocol.Handler,
    name: "BSV20"
end
