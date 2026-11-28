# Builds priv/data/interop/bsv402_v0.json, the published BSV 402 vectors
# (docs/BSV_402.md, section 6).
#
#     MIX_ENV=test mix run --no-start scripts/bsv402_vectors_v0.exs --write
#
# Every `expected` here is declared by hand, never computed by the verifier, so
# test/bitblocks/payments/bsv402_test.exs can hold Bitblocks.Payments.Bsv402 to
# it. That test also evaluates this script and compares the result to the file.
#
# The keys are test keys made for this file from fixed labels, and price_sats
# is the file's own number, not anyone's price.

alias Bitblocks.Bsv402Fixtures, as: F
alias Bitblocks.Interop.Brc42
alias Bitblocks.Payments.Bsv402
alias Jason.OrderedObject, as: O

hex = &Base.encode16(&1, case: :lower)

server = F.server_private()
server_pub = Brc42.public_key(server)
sender = F.sender_private()
sender_pub = F.sender_public()

now_ms = 1_764_000_000_000
price = 100
max_beef_bytes = 12_000
request = O.new(method: "GET", path: "/api/v1/blocks/latest", query: "")
other_request = O.new(method: "GET", path: "/api/v1/blocks/0", query: "")
other_server_pub = F.other_server_public()

# Heights above the chain, so no vector can be taken for a real block.
first_height = 3_100_001

build = fn index, tag, opts ->
  height = first_height + index
  opts = Keyword.put_new(opts, :time, Integer.to_string(now_ms))
  paid = F.payment(F.coin(tag, Keyword.get(opts, :extra, [])), height, price, opts)

  root =
    case Keyword.get(opts, :root, :coin) do
      :coin -> paid.coin_root
      :elsewhere -> F.display(F.label("a root that isn't this coin's"))
    end

  header =
    if Keyword.get(opts, :header?, true) do
      O.new(
        height: height,
        synthetic: true,
        merkleroot: root,
        tx_count: 1,
        note: "Made up for vector #{tag}: a one-tx block holding its coin."
      )
    end

  {paid.txid, header, O.new(paid.headers)}
end

cases = [
  {"pays-exact", "One output of exactly the price, its coin proven.", [], [], "accept",
   {200, "accepted", nil}},
  {"pays-over", "One sat more than the price: at least the price is what BRC-121 asks.",
   [sats: price + 1], [], "accept", {200, "accepted", nil}},
  {"pays-under", "One sat short.", [sats: price - 1], [], "accept",
   {402, "refused", "underpaid"}},
  {"wrong-key", "P2PKH to the key derived for another server.", [pay_to: other_server_pub], [],
   "accept", {402, "refused", "not_our_output"}},
  {"wrong-suffix", "x-bsv-time a second off the time the key was derived for.",
   [header_time: Integer.to_string(now_ms - 1_000)], [], "accept",
   {402, "refused", "not_our_output"}},
  {"wrong-vout", "x-bsv-vout names the change.", [vout: "1"], [], "accept",
   {402, "refused", "not_our_output"}},
  {"stale", "Paid 31 seconds ago.", [time: Integer.to_string(now_ms - 31_000)], [], "accept",
   {402, "refused", "stale"}},
  {"future", "Dated 31 seconds ahead.", [time: Integer.to_string(now_ms + 31_000)], [], "accept",
   {402, "refused", "stale"}},
  {"replay", "Its txid already bought another request.", [], [other_request], "accept",
   {402, "refused", "replayed"}},
  {"replay-same-request",
   "Its txid already bought this same request: served again, with no new claim.", [], [request],
   "accept", {200, "reserved", nil}},
  {"unknown-root", "The coin's BUMP climbs to a root that isn't the header's at that height.",
   [root: :elsewhere], [], "accept", {402, "refused", "unproven"}},
  {"unknown-block", "The coin's BUMP names a height with no header.", [header?: false], [],
   "accept", {402, "refused", "unknown_block"}},
  {"not-atomic", "BEEF V1 without the Atomic prefix (BRC-95).", [wrap: :bare], [], "accept",
   {402, "refused", "malformed"}},
  {"bad-beef", "Atomic BEEF cut short.", [wrap: :truncated], [], "accept",
   {402, "refused", "malformed"}},
  {"missing-header", "No x-bsv-sender.", [drop: ["x-bsv-sender"]], [], "accept",
   {402, "refused", "incomplete"}},
  {"node-rejects", "Our node refuses it, as a double spend.", [], [],
   "reject:bad-txns-inputs-spent", {402, "refused", "broadcast_rejected"}},
  {"node-down", "Our node doesn't answer: nothing is taken.", [], [], "unreachable",
   {503, "refused", "broadcast_unavailable"}},
  {"node-knows-it", "Our node already has it (the wallet broadcast it first).", [], [],
   "already_known", {200, "accepted", nil}},
  {"oversize", "A BEEF over max_beef_bytes: its coin carries #{max_beef_bytes} bytes of data.",
   [
     extra: [
       {0, <<0x00, 0x6A, 0x4D, max_beef_bytes::little-16>> <> :binary.copy(<<0>>, max_beef_bytes)}
     ]
   ], [], "accept", {413, "refused", "too_large"}}
]

{vectors, headers} =
  cases
  |> Enum.with_index()
  |> Enum.map(fn {{id, what, opts, claimed, node, {status, outcome, reason}}, index} ->
    {txid, header, payment} = build.(index, id, opts)

    vector =
      O.new(
        id: id,
        case: what,
        envelope: "brc121",
        request: request,
        payment: payment,
        txid: if(Keyword.get(opts, :wrap, :atomic) == :truncated, do: nil, else: txid),
        claimed: Enum.map(claimed, &O.new(txid: txid, request: &1)),
        node: node,
        expected: O.new(status: status, outcome: outcome, reason: reason)
      )

    {vector, header}
  end)
  |> Enum.unzip()

# Keyed: a caller with an API key past its own budget (docs/BSV_402.md, slice
# B). Added 2026-11-27; the vectors above are unchanged. The tokens are made
# from labels like the keys: 32 bytes, as a real key holds.
token = fn text -> "bbk_" <> Base.url_encode64(F.label(text), padding: false) end
keyed_token = token.("keyed api key")
unknown_token = token.("unknown api key")
keyed_rpm = 1
server_key = hex.(server_pub)

terms = [{"x-bsv-sats", Integer.to_string(price)}, {"x-bsv-server", server_key}]

limit_headers = [
  {"x-ratelimit-limit", Integer.to_string(keyed_rpm)},
  {"x-ratelimit-remaining", "0"}
]

keyed_body = [error: "api_key_rate_limited", budget: "api_key", limit_per_minute: keyed_rpm]

keyed_cases = [
  {"keyed-under-budget", "A key within its budget: served free, counted against the key.",
   keyed_token, 0, nil, [], "accept",
   [
     status: 200,
     outcome: "served",
     reason: nil,
     headers: limit_headers,
     headers_absent: ["x-bsv-txid"]
   ]},
  {"keyed-over-budget",
   "A key past its budget, no payment: a 402 with BRC-121's terms, where it was a 429.",
   keyed_token, keyed_rpm, nil, [], "accept",
   [
     status: 402,
     outcome: "payment_required",
     reason: nil,
     headers: terms ++ limit_headers,
     headers_present: ["retry-after"],
     body: keyed_body
   ]},
  {"keyed-pays",
   "A key past its budget, paying: served, with what was paid, outside the key's budget.",
   keyed_token, keyed_rpm, [], [], "accept",
   [status: 200, outcome: "accepted", reason: nil, headers: :paid]},
  {"keyed-replay", "A key past its budget, its payment's txid already bought another request.",
   keyed_token, keyed_rpm, [], [other_request], "accept",
   [
     status: 402,
     outcome: "refused",
     reason: "replayed",
     headers: [{"x-bsv-refused", "replayed"} | terms],
     body: keyed_body ++ [payment_refused: O.new(protocol: "BRC-121", reason: "replayed")]
   ]},
  {"keyed-bad-key", "An unknown key with a payment: a 401, never a 402; the payment isn't read.",
   unknown_token, 0, [], [], "accept",
   [
     status: 401,
     outcome: "refused",
     reason: "invalid_api_key",
     headers_absent: ["x-bsv-sats", "x-bsv-server", "x-bsv-txid"],
     body: [error: "Invalid API key (unknown or revoked)"]
   ]}
]

{keyed, keyed_headers} =
  keyed_cases
  |> Enum.with_index(length(cases))
  |> Enum.map(fn {{id, what, key_token, spent, pay_opts, claimed, node, expected}, index} ->
    {txid, header, payment} =
      if pay_opts, do: build.(index, id, pay_opts), else: {nil, nil, nil}

    headers =
      case expected[:headers] do
        :paid -> [{"x-bsv-payment-satoshis-paid", Integer.to_string(price)}, {"x-bsv-txid", txid}]
        nil -> []
        list -> list
      end

    vector =
      O.new(
        id: id,
        case: what,
        envelope: "brc121",
        api_key:
          O.new(
            token: key_token,
            registered: key_token == keyed_token,
            requests_per_minute: keyed_rpm,
            spent: spent
          ),
        request: request,
        request_headers: O.new(authorization: "Bearer " <> key_token),
        payment: payment,
        txid: txid,
        claimed: Enum.map(claimed, &O.new(txid: txid, request: &1)),
        node: node,
        expected:
          O.new(
            status: expected[:status],
            outcome: expected[:outcome],
            reason: expected[:reason],
            headers: O.new(headers),
            headers_present: Keyword.get(expected, :headers_present, []),
            headers_absent: Keyword.get(expected, :headers_absent, []),
            body: if(expected[:body], do: O.new(expected[:body]))
          )
      )

    {vector, header}
  end)
  |> Enum.unzip()

doc =
  O.new(
    name: "bitblocks-bsv402-vectors",
    version: "bsv402/v0",
    status: "draft",
    published: "2026-11-23",
    url: "https://bitblocks.app/interop/bsv402/v0.json",
    description:
      "Test vectors for a server taking BRC-121 (Simple 402 Payments): a BRC-29 output in Atomic BEEF, sent in the x-bsv-* headers, checked against the server's own headers and node. Each says what the server should answer.",
    versioning:
      "v0 until a real wallet's payment is in it; then v1. Within a version, a vector's id, bytes and expected outcome stay as they are, except to correct a mistake.",
    basis:
      O.new(
        brc121:
          "https://github.com/bitcoin-sv/BRCs/blob/42ceeb219e686e41a6b7fb85be1231c44b2e2a73/payments/0121.md",
        brc29:
          "https://github.com/bitcoin-sv/BRCs/blob/d403af3417815919218468556503b627cd272abc/payments/0029.md",
        reference_client: "@bsv/402-pay 0.3.6 (its client and server, read 2026-11-23)",
        derivation:
          "test/support/fixtures/brc/bsv402_brc29_sdk.json in the bitblocks repo: @bsv/sdk 4.1.2's keys for these labels"
      ),
    claim:
      "These vectors cover what a server checks before it serves a paid request: the headers, the time, the BEEF, the output and its key, the amount, the proof against headers, the claim and the node's answer. The transactions are unsigned: a real node would refuse them, so each vector names what the stubbed node answers.",
    tried_against:
      "Bitblocks.Payments.Bsv402, and the derivation against @bsv/sdk 4.1.2. No live wallet yet. Nothing in this file says any wallet or server conforms to it.",
    how_to_use: [
      "Take server.identity_private_key as your identity key, price_sats as your price and now_ms as your clock.",
      "Treat every entry in headers as a header you hold, verified and on the best chain, and no others. They are made up: rely on merkleroot alone.",
      "Before a vector, treat each txid in claimed as already taken for the request beside it.",
      "Send the vector's payment headers with its request, and have your node answer as node says: accept, already_known, unreachable, or reject:<reason>.",
      "Compare your status and outcome with expected. reason is the name Bitblocks uses, so yours may differ."
    ],
    derivation:
      O.new(
        protocol: [2, "3241645161d8"],
        key_id: "<x-bsv-nonce> <base64 of the x-bsv-time text>",
        invoice: "2-3241645161d8-<x-bsv-nonce> <base64 of the x-bsv-time text>",
        output:
          "P2PKH to the BRC-42 child of the server's key for that invoice, with the sender's key as counterparty"
      ),
    outcomes:
      O.new(
        accepted: "Served: the payment checks, is claimed, and the node took it.",
        reserved:
          "Served again: the same payment for the same request, already claimed; no new claim.",
        refused:
          "Not served. status says how: 402 with the terms again, 413 too large, 503 try again."
      ),
    server: O.new(identity_private_key: hex.(server), identity_key: hex.(server_pub)),
    sender: O.new(identity_private_key: hex.(sender), identity_key: hex.(sender_pub)),
    now_ms: now_ms,
    window_ms: Bsv402.window_ms(),
    price_sats: price,
    max_beef_bytes: max_beef_bytes,
    headers: Enum.reject(headers ++ keyed_headers, &is_nil/1),
    vectors: vectors,
    changes: [
      O.new(
        date: "2026-11-27",
        change:
          "Added keyed: a caller with an API key past its own budget. The vectors before it are unchanged."
      )
    ],
    keyed_how_to_use: [
      "These run through the server's HTTP front, not the verifier alone: register api_key.token (when registered is true) as a key of requests_per_minute, and make spent requests with it, within the minute, before the vector's own.",
      "Then send request with request_headers and, when payment isn't null, the payment headers, under the same clock, headers and node as the vectors above.",
      "Compare status, each entry in expected.headers exactly, that each of headers_present is there and each of headers_absent isn't, and that the JSON body holds every field in expected.body.",
      "outcome served or accepted: within the key's budget or paid; a paid request isn't counted against the key's budget. payment_required: past it, the terms given. refused: a payment refused (402 with the terms again), or a key refused (401, and no terms, since a payment can't mend a bad key)."
    ],
    keyed: keyed
  )

if "--write" in System.argv() do
  path = Path.expand("../priv/data/interop/bsv402_v0.json", __DIR__)
  File.write!(path, Jason.encode!(doc, pretty: true) <> "\n")
  IO.puts("wrote #{path}: #{length(vectors)} vectors")
end

doc
