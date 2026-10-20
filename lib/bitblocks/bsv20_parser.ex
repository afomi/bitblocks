defmodule Bitblocks.Bsv20Parser do
  @moduledoc """
  Parses BSV-20 / BSV-21 fungible-token inscriptions.

  Unlike the OrderBook, Metanet, and Twetch protocols — which live in `OP_RETURN`
  push-data chunks — BSV-20/21 tokens are **1Sat Ordinal inscriptions**. The token
  JSON is carried inside an inscription envelope *in an output's locking script*:

      OP_FALSE OP_IF "ord" OP_1 <content-type> OP_0 <body> OP_ENDIF <...P2PKH...>

  where `<content-type>` is `application/bsv-20` and `<body>` is a JSON document.
  Because the envelope sits in the locking script (not an `OP_RETURN`), this parser
  works over a `BSV.Script`'s `chunks` list rather than over parsed `OP_RETURN`
  data. `BSV.Script` chunks are a list in which binaries are push-data and atoms
  are opcodes (`:OP_FALSE`, `:OP_IF`, `:OP_0`, `:OP_ENDIF`, …).

  Two standards are recognised (see docs/BSV20_TOKENS.md):

  - **BSV-21** (`id`-based, tickerless) — fully indexed. A single `deploy+mint`
    output mints the whole supply; the token id is `"<txid>_<vout>"` of that
    output. `transfer` moves an `id`-referenced balance. This id format is exactly
    the `token_id` the Open Order Book already carries, so tokens resolve
    end-to-end into the DEX.

  - **BSV-20 classic** (`tick`-based, first-is-first) — detect-only in v1. Its
    `deploy` / `mint` / `transfer` ops are parsed into a normalized map and flagged
    `standard: "bsv-20"`, but the cross-transaction supply aggregation
    (mint-progress vs `max`, ticker de-duplication) is deferred to a later version.

  All BSV-20/21 JSON field values are strings per the spec; this parser keeps them
  as strings and does not coerce numeric fields.
  """

  @content_type "application/bsv-20"
  @protocol "bsv-20"

  # A body larger than this is not a token inscription we index — reject rather
  # than hand a huge blob to Jason. Token JSON is a handful of short fields.
  @max_body_bytes 4096

  @type token :: %{
          standard: String.t(),
          op: String.t(),
          token_id: String.t() | nil,
          tick: String.t() | nil,
          amt: String.t() | nil,
          max: String.t() | nil,
          lim: String.t() | nil,
          dec: String.t() | nil,
          sym: String.t() | nil,
          icon: String.t() | nil
        }

  @doc """
  Parses a BSV-20/21 token inscription from a `BSV.Script` (or its `chunks` list).

  Returns `{:ok, token_map}` or `{:error, reason}`. `token_map` always carries a
  `:standard` (`"bsv-21"` or `"bsv-20"`) and an `:op`. For a BSV-21 `deploy+mint`
  the `:token_id` is left `nil` here and stamped as `"<txid>_<vout>"` by the caller
  once the outpoint is known (`Bitblocks.Tokens.index_token/1`).

  ## Examples

      iex> {:ok, %{standard: "bsv-21", op: "deploy+mint", amt: "21000000"}} =
      ...>   Bsv20Parser.parse(script)
  """
  @spec parse(BSV.Script.t() | list()) :: {:ok, map()} | {:error, atom()}
  def parse(%BSV.Script{chunks: chunks}), do: parse(chunks)

  def parse(chunks) when is_list(chunks) do
    with {:ok, content_type, body} <- extract_inscription(chunks),
         :ok <- validate_content_type(content_type),
         {:ok, json} <- decode_body(body) do
      parse_token(json)
    end
  end

  def parse(_), do: {:error, :invalid_data}

  @doc """
  True if a `BSV.Script` (or chunk list) carries a BSV-20/21 token inscription.

  A cheap gate for the detection path (`TransactionParser`) — avoids a full JSON
  parse just to decide whether an output is a token.
  """
  @spec token_inscription?(BSV.Script.t() | list()) :: boolean()
  def token_inscription?(%BSV.Script{chunks: chunks}), do: token_inscription?(chunks)

  def token_inscription?(chunks) when is_list(chunks) do
    case extract_inscription(chunks) do
      {:ok, content_type, _body} -> content_type == @content_type
      _ -> false
    end
  end

  def token_inscription?(_), do: false

  # -- Envelope extraction ----------------------------------------------------

  # Walk the chunk list to the start of an inscription envelope
  # (`OP_FALSE OP_IF "ord"`), then read the field/value pairs up to `OP_ENDIF`.
  # An inscription is:
  #
  #   OP_FALSE OP_IF
  #     "ord"
  #     OP_1 <content-type>     # field 1 = content type
  #     OP_0 <body>             # field 0 = body
  #   OP_ENDIF
  #
  # Fields may appear in any order and other fields may be present; we only need
  # the content type (tag OP_1 / 0x01) and the body (tag OP_0 / the OP_FALSE that
  # separates the body). We scan for the "ord" marker to be tolerant of the
  # leading push (`OP_FALSE`) sometimes being rendered as `:OP_0`.
  defp extract_inscription([]), do: {:error, :no_inscription}

  defp extract_inscription([marker, :OP_IF | rest]) when marker in [:OP_FALSE, :OP_0] do
    case rest do
      ["ord" | body_chunks] -> read_envelope_fields(body_chunks, nil, nil)
      _ -> {:error, :no_inscription}
    end
  end

  defp extract_inscription([_chunk | rest]), do: extract_inscription(rest)

  # Read (tag, value) pairs inside the envelope until OP_ENDIF.
  #   tag OP_1 (or push <<1>>)  → content type is the next push
  #   tag OP_0 (or OP_FALSE)    → body is the next push
  defp read_envelope_fields([:OP_ENDIF | _], content_type, body),
    do: finalize_envelope(content_type, body)

  defp read_envelope_fields([], content_type, body),
    do: finalize_envelope(content_type, body)

  defp read_envelope_fields([tag, value | rest], content_type, body) do
    cond do
      content_type_tag?(tag) and is_binary(value) ->
        read_envelope_fields(rest, safe_string(value), body)

      body_tag?(tag) and is_binary(value) ->
        read_envelope_fields(rest, content_type, value)

      true ->
        # Unknown field tag — skip its value and continue.
        read_envelope_fields(rest, content_type, body)
    end
  end

  defp read_envelope_fields([_lone | rest], content_type, body),
    do: read_envelope_fields(rest, content_type, body)

  defp finalize_envelope(_content_type, nil), do: {:error, :no_inscription_body}
  defp finalize_envelope(content_type, body), do: {:ok, content_type, body}

  # The content-type field tag is OP_1 (pushnum 1). BSV.Script decodes the
  # pushnum opcode as :OP_TRUE (its alias for OP_1); some encoders emit a literal
  # single-byte push <<1>>.
  defp content_type_tag?(:OP_1), do: true
  defp content_type_tag?(:OP_TRUE), do: true
  defp content_type_tag?(<<1>>), do: true
  defp content_type_tag?(_), do: false

  # The body field tag is OP_0 / OP_FALSE (field number 0) — same opcode, two
  # atom aliases depending on how the script was decoded.
  defp body_tag?(:OP_0), do: true
  defp body_tag?(:OP_FALSE), do: true
  defp body_tag?(_), do: false

  defp validate_content_type(@content_type), do: :ok
  defp validate_content_type(_), do: {:error, :not_bsv20}

  defp decode_body(body) when byte_size(body) > @max_body_bytes,
    do: {:error, :body_too_large}

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, %{} = json} -> {:ok, json}
      {:ok, _} -> {:error, :not_a_json_object}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  # -- Token normalization ----------------------------------------------------

  defp parse_token(%{"p" => @protocol, "op" => op} = json) do
    case op do
      # BSV-21 (tickerless / id-based) — fully indexed.
      "deploy+mint" -> parse_deploy_mint(json)
      "transfer" -> parse_transfer(json)
      # BSV-20 classic (ticker / first-is-first) — detect-only in v1.
      "deploy" -> parse_classic_deploy(json)
      "mint" -> parse_classic_mint(json)
      _ -> {:error, :unknown_operation}
    end
  end

  # Right protocol, missing/blank op.
  defp parse_token(%{"p" => @protocol}), do: {:error, :missing_operation}
  # Any other "p" (or none) is not a token we index.
  defp parse_token(_), do: {:error, :not_bsv20}

  # BSV-21 deploy+mint: {p, op:"deploy+mint", amt (req), sym?, dec?, icon?}.
  # token_id is stamped downstream as "<txid>_<vout>".
  defp parse_deploy_mint(%{"amt" => amt} = json) when is_binary(amt) and amt != "" do
    {:ok,
     %{
       standard: "bsv-21",
       op: "deploy+mint",
       token_id: nil,
       tick: nil,
       amt: amt,
       max: amt,
       lim: nil,
       dec: opt(json, "dec"),
       sym: opt(json, "sym"),
       icon: opt(json, "icon")
     }}
  end

  defp parse_deploy_mint(_), do: {:error, :missing_amt}

  # BSV-21 transfer: {p, op:"transfer", id:"<txid>_<vout>" (req), amt (req)}.
  # A "tick" transfer with no "id" is a BSV-20 classic transfer (detect-only).
  defp parse_transfer(%{"id" => id, "amt" => amt})
       when is_binary(id) and id != "" and is_binary(amt) and amt != "" do
    {:ok,
     %{
       standard: "bsv-21",
       op: "transfer",
       token_id: id,
       tick: nil,
       amt: amt,
       max: nil,
       lim: nil,
       dec: nil,
       sym: nil,
       icon: nil
     }}
  end

  defp parse_transfer(%{"tick" => tick, "amt" => amt})
       when is_binary(tick) and tick != "" and is_binary(amt) and amt != "" do
    {:ok,
     %{
       standard: "bsv-20",
       op: "transfer",
       token_id: nil,
       tick: tick,
       amt: amt,
       max: nil,
       lim: nil,
       dec: nil,
       sym: nil,
       icon: nil
     }}
  end

  defp parse_transfer(_), do: {:error, :missing_transfer_fields}

  # BSV-20 classic deploy: {p, op:"deploy", tick (req), max (req), lim?, dec?}.
  defp parse_classic_deploy(%{"tick" => tick, "max" => max} = json)
       when is_binary(tick) and tick != "" and is_binary(max) and max != "" do
    {:ok,
     %{
       standard: "bsv-20",
       op: "deploy",
       token_id: nil,
       tick: tick,
       amt: nil,
       max: max,
       lim: opt(json, "lim"),
       dec: opt(json, "dec"),
       sym: nil,
       icon: nil
     }}
  end

  defp parse_classic_deploy(_), do: {:error, :missing_deploy_fields}

  # BSV-20 classic mint: {p, op:"mint", tick (req), amt (req)}.
  defp parse_classic_mint(%{"tick" => tick, "amt" => amt})
       when is_binary(tick) and tick != "" and is_binary(amt) and amt != "" do
    {:ok,
     %{
       standard: "bsv-20",
       op: "mint",
       token_id: nil,
       tick: tick,
       amt: amt,
       max: nil,
       lim: nil,
       dec: nil,
       sym: nil,
       icon: nil
     }}
  end

  defp parse_classic_mint(_), do: {:error, :missing_mint_fields}

  # -- Helpers ----------------------------------------------------------------

  defp opt(json, key) do
    case Map.get(json, key) do
      value when is_binary(value) and value != "" -> value
      # Some encoders emit numeric amt/dec; keep as a string for consistency.
      value when is_integer(value) -> Integer.to_string(value)
      _ -> nil
    end
  end

  defp safe_string(binary) when is_binary(binary) do
    if String.valid?(binary), do: binary, else: Base.encode16(binary, case: :lower)
  end
end
