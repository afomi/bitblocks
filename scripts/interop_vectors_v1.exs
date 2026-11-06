# Builds priv/data/interop/vectors_v1.json, the published interoperability
# vectors (docs/INTEROP_KIT.md).
#
#     MIX_ENV=test mix run --no-start scripts/interop_vectors_v1.exs --write
#
# Every `expected` here is declared by hand, never computed by the checker, so
# test/bitblocks/interop/vectors_test.exs can hold the checker to it. That test
# also evaluates this script and compares the result to the published file.

alias Bitblocks.Chain.Beef
alias Bitblocks.Chain.Beef.Reader
alias Bitblocks.Chain.HeaderVerifier
alias Bitblocks.RealHeaders
alias Jason.OrderedObject, as: O

fixtures = Path.expand("../test/support/fixtures/brc", __DIR__)
hex_fixture = fn name -> fixtures |> Path.join(name) |> File.read!() |> String.trim() end
json_fixture = fn name -> fixtures |> Path.join(name) |> File.read!() |> Jason.decode!() end
unhex = &Base.decode16!(&1, case: :lower)
hex = &Base.encode16(&1, case: :lower)

sha256d = fn bytes -> :crypto.hash(:sha256, :crypto.hash(:sha256, bytes)) end

reverse = fn bytes ->
  bytes |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
end

display = fn hash -> hash |> reverse.() |> hex.() end

v1 = <<0x01, 0x00, 0xBE, 0xEF>>
v2 = <<0x02, 0x00, 0xBE, 0xEF>>

# --- what the vectors are made from ----------------------------------------------

brc62_bytes = unhex.(hex_fixture.("brc62_beef.hex"))
brc74_bytes = unhex.(hex_fixture.("brc74_bump.hex"))
sdk = json_fixture.("beef_sdk_v1.json")
two_input = json_fixture.("vault_beef_v1.json")
mainnet = json_fixture.("woc_mainnet_v1.json")

{:ok, brc62} = Reader.parse(brc62_bytes)
[brc62_bump] = brc62.bumps
[brc62_parent, brc62_payment] = brc62.transactions

mainnet_raw = unhex.(mainnet["rawTx"])
mainnet_bump = unhex.(mainnet["bump"])
mainnet_v1 = <<v1::binary, 1, mainnet_bump::binary, 1, mainnet_raw::binary, 1, 0>>
mainnet_v2 = <<v2::binary, 1, mainnet_bump::binary, 1, 1, 0, mainnet_raw::binary>>

[mined_input, unconfirmed_input] = two_input["facts"]["inputs"]
two_input_height = mined_input["anchor"]["blockHeight"]

# A minimal tx spending `prev` (internal bytes), told apart by `tag`.
tx = fn prev, tag ->
  <<1::little-32, 1, prev::binary, tag::little-32, 0, 0xFFFFFFFF::little-32, 1, 1000::little-64,
    1, 0x51, 0::little-32>>
end

label = fn text -> :crypto.hash(:sha256, "bitblocks interop vectors v1: " <> text) end
leaf = fn offset, hash, txid? -> %{offset: offset, hash: hash, txid: txid?, duplicate: false} end

crafted_a = tx.(label.("a"), 0)
crafted_b = tx.(crafted_a |> sha256d.(), 0)
crafted_c = tx.(crafted_b |> sha256d.(), 0)
crafted_lone = tx.(label.("lone"), 0)
crafted_pair = tx.(label.("pair"), 0)
sibling = label.("sibling")

coinbase =
  <<1::little-32, 1, 0::256, 0xFFFFFFFF::little-32, 2, 0x51, 0x51, 0xFFFFFFFF::little-32, 1,
    5_000_000_000::little-64, 1, 0x51, 0::little-32>>

sixty_four =
  <<1::little-32, 1, label.("64")::binary, 0::little-32, 0, 0::little-32, 1, 0::little-64, 4,
    0x51, 0x51, 0x51, 0x51, 0::little-32>>

64 = byte_size(sixty_four)

# Heights above the chain, so a crafted vector can't be taken for a real block.
[h_chain, h_lone, h_incomplete, h_tree, h_past, h_64] = Enum.to_list(3_000_001..3_000_006)

pair_root = display.(sha256d.(sibling <> sha256d.(crafted_pair)))

bump_at = fn height, path -> %{height: height, path: path} end

# --- sources --------------------------------------------------------------------

source = fn id, title, url, how, licence ->
  O.new(id: id, title: title, url: url, how: how, licence: licence)
end

brcs = "https://github.com/bsv-blockchain/BRCs/blob/master/transactions/"

sources = [
  source.(
    "brc-62",
    "The worked example in BRC-62",
    brcs <> "0062.md",
    "Copied byte for byte from the BRC's example. Its authors are listed in the BRC.",
    "The BRC states: \"This BRC is licensed under the Open BSV license.\" It names no version. © BSV Association."
  ),
  source.(
    "brc-74",
    "The worked example in BRC-74",
    brcs <> "0074.md",
    "Copied byte for byte from the BRC's example. Its authors are listed in the BRC.",
    "The BRC states: \"This BRC is licensed under the Open BSV license.\" It names no version. © BSV Association."
  ),
  source.(
    "bsv-sdk-2.4.0",
    "Bytes written by @bsv/sdk 2.4.0",
    "https://www.npmjs.com/package/@bsv/sdk/v/2.4.0",
    "Output of Beef.toBinaryAtomic and of Beef.toBinary with version BEEF_V2, run once. No SDK code is included.",
    "The package ships under the Open BSV License Version 6, © BSV Association (its LICENSE.txt)."
  ),
  source.(
    "bsv-sdk-2.8.11",
    "Bytes written by @bsv/sdk 2.8.11",
    "https://www.npmjs.com/package/@bsv/sdk/v/2.8.11",
    "A BEEF V1 test vector shared with Bitblocks, whose own note says @bsv/sdk 2.8.11 generated it. We did not regenerate it. No SDK code is included.",
    "The package ships under the Open BSV License Version 6, © BSV Association (its LICENSE.txt)."
  ),
  source.(
    "whatsonchain",
    "One mainnet transaction and its merkle path, from WhatsOnChain",
    "https://api.whatsonchain.com/v1/bsv/main/tx/#{mainnet["txid"]}/hex",
    "Fetched 2026-10-28 from /tx/<txid>/hex and /tx/<txid>/proof/bump. WhatsOnChain is named as the source, and has not reviewed this kit.",
    "Public chain data. Check it against the chain rather than taking our copy on trust."
  ),
  source.(
    "bitblocks",
    "Composed or crafted by Bitblocks",
    "https://github.com/afomi/bitblocks/blob/develop/scripts/interop_vectors_v1.exs",
    "Built by the script at this URL. Each vector's description says what was changed or put together.",
    "MIT, as the Bitblocks repository."
  )
]

# --- headers --------------------------------------------------------------------

real_header = fn height, tx_count, src ->
  fields = RealHeaders.fields(height)

  {:ok, raw} =
    HeaderVerifier.serialize(%{
      "version" => fields.version,
      "previousblockhash" => fields.prevblockhash,
      "merkleroot" => fields.merkleroot,
      "time" => fields.time,
      "bits" => fields.bits,
      "nonce" => fields.nonce
    })

  O.new(
    height: height,
    synthetic: false,
    hash: fields.hash,
    merkleroot: fields.merkleroot,
    tx_count: tx_count,
    raw_header: hex.(raw),
    note: src
  )
end

synthetic_header = fn height, root, tx_count, note ->
  O.new(
    height: height,
    synthetic: true,
    hash: nil,
    merkleroot: root,
    tx_count: tx_count,
    raw_header: nil,
    note: note
  )
end

crafted_note = "A height above the chain, made for this vector. No such block exists."

headers = [
  real_header.(813_706, 3051, "Mainnet, the block of BRC-74's example."),
  real_header.(814_435, 106, "Mainnet, the block of BRC-62's example."),
  real_header.(
    973_110,
    nil,
    "Mainnet. We hold no transaction count for it here, so none is stated."
  ),
  synthetic_header.(
    two_input_height,
    mined_input["anchor"]["merkleRoot"],
    nil,
    "A test value. The real block at this height has a different merkle root, so these vectors read failed against real headers. Use this entry in place of the real header for them."
  ),
  synthetic_header.(h_chain, display.(sha256d.(crafted_a)), nil, crafted_note),
  synthetic_header.(h_lone, display.(sha256d.(crafted_lone)), 1, crafted_note),
  synthetic_header.(h_incomplete, String.duplicate("0", 64), nil, crafted_note),
  synthetic_header.(h_tree, pair_root, 1000, crafted_note),
  synthetic_header.(h_past, pair_root, 1, crafted_note),
  synthetic_header.(h_64, display.(sha256d.(sixty_four)), nil, crafted_note)
]

# --- vectors --------------------------------------------------------------------

entry = fn status, reason, txid, height ->
  O.new(txid: txid, status: status, reason: reason, block_height: height)
end

answer = fn outcome, reason, format, subject, height, txs ->
  O.new(
    outcome: outcome,
    reason: reason,
    format: format,
    subject_txid: subject,
    in_block: outcome == "proven",
    block_height: height,
    transactions: txs
  )
end

refused = fn reason -> O.new(outcome: "refused", reason: reason) end

climbs = fn height, root, leaves ->
  O.new(
    outcome: "root",
    block_height: height,
    merkleroot: root,
    leaves: for({txid, offset} <- leaves, do: O.new(txid: txid, offset: offset))
  )
end

vector = fn id, kind, valid, basis, srcs, title, description, hex_bytes, held, expected ->
  O.new(
    id: id,
    kind: kind,
    valid: valid,
    basis: basis,
    sources: srcs,
    title: title,
    description: description,
    hex: hex_bytes,
    headers_held: held,
    expected: expected
  )
end

beef = fn id, valid, basis, srcs, title, description, bytes, held, expected ->
  vector.(id, "beef", valid, basis, srcs, title, description, hex.(bytes), held, expected)
end

bump = fn id, valid, basis, srcs, title, description, bytes, held, expected ->
  vector.(id, "bump", valid, basis, srcs, title, description, hex.(bytes), held, expected)
end

parent_id = brc62_parent.txid
payment_id = brc62_payment.txid
mainnet_id = mainnet["txid"]

brc62_held = [
  entry.("proven", nil, parent_id, 814_435),
  entry.("anchored", nil, payment_id, nil)
]

two_input_txs = [
  entry.("proven", nil, mined_input["txid"], two_input_height),
  entry.("anchored", nil, unconfirmed_input["txid"], nil),
  entry.("anchored", nil, two_input["unsignedTxid"], nil)
]

mainnet_proven = fn format ->
  answer.("proven", nil, format, mainnet_id, 973_110, [
    entry.("proven", nil, mainnet_id, 973_110)
  ])
end

tampered_parent =
  (fn ->
     size = byte_size(brc62_parent.raw) - 1
     <<head::binary-size(size), byte>> = brc62_parent.raw
     <<head::binary, Bitwise.bxor(byte, 1)>>
   end).()

tampered_bump =
  (fn ->
     [level_0 | rest] = brc62_bump.path

     changed =
       Enum.map(level_0, fn
         %{txid: false, hash: hash} = leaf when is_binary(hash) ->
           %{leaf | hash: :crypto.hash(:sha256, hash)}

         leaf ->
           leaf
       end)

     %{brc62_bump | path: [changed | rest]}
   end).()

valid_vectors = [
  beef.(
    "brc62-example",
    true,
    "BRC-62",
    ["brc-62"],
    "BRC-62's example: a proven parent and a fresh payment",
    "The spec's own example. The parent has a BUMP into block 814435, and the subject has none, so it is anchored and is not shown to be in a block.",
    brc62_bytes,
    [814_435],
    answer.("anchored", nil, "beef_v1", payment_id, nil, brc62_held)
  ),
  beef.(
    "brc62-example-no-header",
    true,
    "BRC-62",
    ["brc-62"],
    "The same bytes, with no header at that height",
    "Good bytes and a checker that holds no header at 814435. The answer is unknown, never a pass.",
    brc62_bytes,
    [],
    answer.("unknown", "ancestor_unknown", "beef_v1", payment_id, nil, [
      entry.("unknown", "height_unknown", parent_id, 814_435),
      entry.("unknown", "ancestor_unknown", payment_id, nil)
    ])
  ),
  beef.(
    "brc62-atomic-sdk",
    true,
    "BRC-95",
    ["brc-62", "bsv-sdk-2.4.0"],
    "BRC-62's example as Atomic BEEF",
    "The SDK's Atomic BEEF around the BRC-62 transactions. BRC-95 doesn't say which byte order the subject takes; this vector has it in internal order, as the SDK writes it.",
    unhex.(sdk["brc62_atomic"]),
    [814_435],
    answer.("anchored", nil, "atomic_beef_v1", payment_id, nil, brc62_held)
  ),
  beef.(
    "brc62-v2-txid-only-sdk",
    true,
    "hardening",
    ["brc-62", "bsv-sdk-2.4.0"],
    "BEEF V2 with the parent as a txid alone",
    "BRC-96 lets two parties who already share a transaction send its txid and treat it as valid. A third party has no such agreement, so a checker with no earlier exchange answers unknown.",
    unhex.(sdk["brc62_v2_txid_only"]),
    [814_435],
    answer.("unknown", "ancestor_unknown", "beef_v2", payment_id, nil, [
      entry.("unknown", "txid_only", parent_id, nil),
      entry.("unknown", "ancestor_unknown", payment_id, nil)
    ])
  ),
  beef.(
    "two-input-v1-sdk",
    true,
    "BRC-62",
    ["bsv-sdk-2.8.11"],
    "Two inputs: one mined, one unconfirmed, BEEF V1",
    "A test transaction spending a proven output and an unconfirmed one. Its merkle root is a test value, so hold the synthetic header at this height. Against real headers it reads failed.",
    unhex.(two_input["unsignedBeef"]),
    [two_input_height],
    answer.("anchored", nil, "beef_v1", two_input["unsignedTxid"], nil, two_input_txs)
  ),
  beef.(
    "two-input-v2-sdk",
    true,
    "BRC-96",
    ["bsv-sdk-2.8.11", "bsv-sdk-2.4.0"],
    "The same transactions as BEEF V2",
    "Rewritten by @bsv/sdk 2.4.0 from the BEEF V1 above. The same test merkle root applies.",
    unhex.(sdk["v2"]),
    [two_input_height],
    answer.("anchored", nil, "beef_v2", two_input["unsignedTxid"], nil, two_input_txs)
  ),
  beef.(
    "two-input-atomic-sdk",
    true,
    "BRC-95",
    ["bsv-sdk-2.8.11", "bsv-sdk-2.4.0"],
    "The same transactions as Atomic BEEF",
    "Rewritten by @bsv/sdk 2.4.0 from the BEEF V1 above. The same test merkle root applies.",
    unhex.(sdk["atomic_v1"]),
    [two_input_height],
    answer.("anchored", nil, "atomic_beef_v1", two_input["unsignedTxid"], nil, two_input_txs)
  ),
  beef.(
    "mainnet-v1",
    true,
    "BRC-62",
    ["whatsonchain", "bitblocks"],
    "A real mainnet transaction, BEEF V1",
    "WhatsOnChain's transaction and BUMP, put together as BEEF V1 by Bitblocks. The subject has its own proof, against a real header.",
    mainnet_v1,
    [973_110],
    mainnet_proven.("beef_v1")
  ),
  beef.(
    "mainnet-v2",
    true,
    "BRC-96",
    ["whatsonchain", "bitblocks"],
    "The same transaction, BEEF V2",
    "The same bytes in the V2 layout, put together by Bitblocks.",
    mainnet_v2,
    [973_110],
    mainnet_proven.("beef_v2")
  ),
  beef.(
    "mainnet-atomic-v1",
    true,
    "BRC-95",
    ["whatsonchain", "bitblocks"],
    "The same transaction, Atomic BEEF around V1",
    "The Atomic prefix and subject around the V1 vector, subject in internal byte order.",
    Beef.atomic(mainnet_v1, mainnet_id),
    [973_110],
    mainnet_proven.("atomic_beef_v1")
  ),
  beef.(
    "mainnet-atomic-v2",
    true,
    "BRC-95",
    ["whatsonchain", "bitblocks"],
    "The same transaction, Atomic BEEF around V2",
    "The Atomic prefix and subject around the V2 vector, subject in internal byte order.",
    Beef.atomic(mainnet_v2, mainnet_id),
    [973_110],
    mainnet_proven.("atomic_beef_v2")
  ),
  beef.(
    "anchored-chain",
    true,
    "BRC-62",
    ["bitblocks"],
    "A chain of unconfirmed transactions from one proof",
    "Crafted: a proven transaction, a child and a grandchild. Anchoring carries down the chain.",
    Beef.encode([bump_at.(h_chain, [[leaf.(0, sha256d.(crafted_a), true)]])], [
      {crafted_a, 0},
      {crafted_b, nil},
      {crafted_c, nil}
    ]),
    [h_chain],
    answer.("anchored", nil, "beef_v1", Reader.txid(crafted_c), nil, [
      entry.("proven", nil, Reader.txid(crafted_a), h_chain),
      entry.("anchored", nil, Reader.txid(crafted_b), nil),
      entry.("anchored", nil, Reader.txid(crafted_c), nil)
    ])
  ),
  beef.(
    "one-transaction-block",
    true,
    "BRC-74",
    ["bitblocks"],
    "A block of one transaction",
    "Crafted: the transaction is its block's merkle root, so its BUMP is one leaf at level 0.",
    Beef.encode([bump_at.(h_lone, [[leaf.(0, sha256d.(crafted_lone), true)]])], [
      {crafted_lone, 0}
    ]),
    [h_lone],
    answer.("proven", nil, "beef_v1", Reader.txid(crafted_lone), h_lone, [
      entry.("proven", nil, Reader.txid(crafted_lone), h_lone)
    ])
  ),
  bump.(
    "brc74-example",
    true,
    "BRC-74",
    ["brc-74"],
    "BRC-74's example: three transactions, one path",
    "The spec's own example. Each named txid climbs to the root in block 813706's header.",
    brc74_bytes,
    [813_706],
    climbs.(813_706, "57aab6e6fb1b697174ffb64e062c4728f2ffd33ddcfa02a43b64d8cd29b483b4", [
      {"304e737fdfcb017a1a322e78b067ecebb5e07b44f0a36ed1f01264d2014f7711", 3048},
      {"d888711d588021e588984e8278a2decf927298173a06737066e43f3e75534e00", 3049},
      {"98c9c5dd79a18f40837061d5e0395ffb52e700a2689e641d19f053fc9619445e", 3050}
    ])
  ),
  bump.(
    "mainnet-bump",
    true,
    "BRC-74",
    ["whatsonchain"],
    "A real mainnet path",
    "WhatsOnChain's BUMP for one transaction in block 973110.",
    mainnet_bump,
    [973_110],
    climbs.(973_110, mainnet["merkleRoot"], [{mainnet_id, 1}])
  )
]

# A hash to fill a leaf; these BUMPs are refused before it matters.
filler = label.("filler")

refused_vectors = [
  beef.(
    "refused-empty",
    false,
    "BRC-62",
    ["bitblocks"],
    "No bytes at all",
    "An empty input.",
    <<>>,
    [],
    refused.("truncated")
  ),
  beef.(
    "refused-unknown-version",
    false,
    "BRC-62",
    ["bitblocks"],
    "A version we can't read",
    "0300beef isn't a defined BEEF version.",
    <<0x03, 0x00, 0xBE, 0xEF, 0, 0>>,
    [],
    refused.("unknown_format")
  ),
  beef.(
    "refused-truncated",
    false,
    "BRC-62",
    ["whatsonchain", "bitblocks"],
    "Cut one byte short",
    "mainnet-v1 without its last byte.",
    binary_part(mainnet_v1, 0, byte_size(mainnet_v1) - 1),
    [],
    refused.("truncated")
  ),
  beef.(
    "refused-trailing-bytes",
    false,
    "hardening",
    ["whatsonchain", "bitblocks"],
    "A byte past the end",
    "mainnet-v1 with one more byte.",
    mainnet_v1 <> <<0>>,
    [],
    refused.("trailing_bytes")
  ),
  beef.(
    "refused-no-transactions",
    false,
    "hardening",
    ["bitblocks"],
    "No transactions",
    "No BUMPs and no transactions, so there is no subject.",
    <<v1::binary, 0, 0>>,
    [],
    refused.("no_transactions")
  ),
  beef.(
    "refused-varint-not-minimal",
    false,
    "hardening",
    ["whatsonchain", "bitblocks"],
    "A VarInt longer than it needs to be",
    "mainnet-v1 with its BUMP count written as fd0100.",
    <<v1::binary, 0xFD, 1, 0, mainnet_bump::binary, 1, mainnet_raw::binary, 1, 0>>,
    [],
    refused.("varint_not_minimal")
  ),
  beef.(
    "refused-no-inputs",
    false,
    "hardening",
    ["bitblocks"],
    "A transaction with no inputs",
    "This also refuses Extended Format, whose marker reads as an input count of zero. BEEF carries raw transactions (BRC-12).",
    <<v1::binary, 0, 1, 1::little-32, 0, 1, 0::little-64, 1, 0x51, 0::little-32, 0>>,
    [],
    refused.("bad_transaction")
  ),
  beef.(
    "refused-has-bump-flag",
    false,
    "BRC-62",
    ["whatsonchain", "bitblocks"],
    "A has-BUMP flag other than 0 or 1",
    "mainnet-v1 with the flag set to 02.",
    <<v1::binary, 1, mainnet_bump::binary, 1, mainnet_raw::binary, 2>>,
    [],
    refused.("bad_transaction_flag")
  ),
  beef.(
    "refused-v2-format-byte",
    false,
    "BRC-96",
    ["bitblocks"],
    "A BEEF V2 format byte outside 00, 01 and 02",
    "One transaction entry with format 03.",
    <<v2::binary, 0, 1, 3>>,
    [],
    refused.("bad_transaction_flag")
  ),
  beef.(
    "refused-bump-index",
    false,
    "BRC-62",
    ["whatsonchain", "bitblocks"],
    "A BUMP index past the list",
    "mainnet-v1 pointing at a second BUMP it doesn't have.",
    <<v1::binary, 1, mainnet_bump::binary, 1, mainnet_raw::binary, 1, 1>>,
    [],
    refused.("bump_index_out_of_range")
  ),
  beef.(
    "refused-duplicate-transaction",
    false,
    "hardening",
    ["whatsonchain", "bitblocks"],
    "The same transaction twice",
    "mainnet-v1's transaction listed two times.",
    <<v1::binary, 1, mainnet_bump::binary, 2, mainnet_raw::binary, 1, 0, mainnet_raw::binary, 1,
      0>>,
    [],
    refused.("duplicate_transaction")
  ),
  beef.(
    "refused-out-of-order",
    false,
    "BRC-62",
    ["brc-62", "bitblocks"],
    "A child ahead of its parent",
    "BRC-62's example with its two transactions swapped.",
    Beef.encode([brc62_bump], [{brc62_payment.raw, nil}, {brc62_parent.raw, 0}]),
    [],
    refused.("transactions_out_of_order")
  ),
  beef.(
    "refused-atomic-subject-missing",
    false,
    "BRC-95",
    ["whatsonchain", "bitblocks"],
    "Atomic BEEF naming a transaction it doesn't hold",
    "mainnet-v1 wrapped with BRC-62's payment as the subject.",
    Beef.atomic(mainnet_v1, payment_id),
    [],
    refused.("atomic_subject_missing")
  ),
  beef.(
    "refused-atomic-unrelated",
    false,
    "BRC-95",
    ["brc-62", "bitblocks"],
    "Atomic BEEF holding a transaction outside the subject's ancestry",
    "BRC-62's example wrapped with the parent as the subject, so the payment is unrelated.",
    Beef.atomic(brc62_bytes, parent_id),
    [],
    refused.("atomic_unrelated_transaction")
  ),
  bump.(
    "refused-bump-block-height",
    false,
    "hardening",
    ["bitblocks"],
    "A block height past 2^32 - 1",
    "A height no block header can hold.",
    <<0xFF, 0x1_0000_0000::little-64, 1, 1, 0, 2, filler::binary>>,
    [],
    refused.("block_height_out_of_range")
  ),
  bump.(
    "refused-bump-tree-height-zero",
    false,
    "hardening",
    ["bitblocks"],
    "A tree height of 0",
    "A BUMP with no levels proves nothing.",
    <<7, 0>>,
    [],
    refused.("tree_height_out_of_range")
  ),
  bump.(
    "refused-bump-tree-height-65",
    false,
    "BRC-74",
    ["bitblocks"],
    "A tree height of 65",
    "BRC-74 caps the tree height at 64.",
    <<7, 65>>,
    [],
    refused.("tree_height_out_of_range")
  ),
  bump.(
    "refused-bump-empty-level-zero",
    false,
    "hardening",
    ["bitblocks"],
    "No leaves at level 0",
    "Nothing to climb from.",
    <<7, 1, 0>>,
    [],
    refused.("empty_level")
  ),
  bump.(
    "refused-bump-offset",
    false,
    "hardening",
    ["bitblocks"],
    "An offset that can't fit the tree",
    "Offset 2 in a tree of height 1.",
    <<7, 1, 1, 2, 2, filler::binary>>,
    [],
    refused.("offset_out_of_range")
  ),
  bump.(
    "refused-bump-duplicate-offset",
    false,
    "hardening",
    ["bitblocks"],
    "Two leaves at one offset",
    "Both at offset 0.",
    <<7, 1, 2, 0, 2, filler::binary, 0, 0, filler::binary>>,
    [],
    refused.("duplicate_offset")
  ),
  bump.(
    "refused-bump-leaf-flag",
    false,
    "BRC-74",
    ["bitblocks"],
    "A leaf flag outside 00, 01 and 02",
    "Flag 03.",
    <<7, 1, 1, 0, 3>>,
    [],
    refused.("bad_leaf_flag")
  ),
  bump.(
    "refused-bump-duplicate-at-even-offset",
    false,
    "hardening",
    ["bitblocks"],
    "A duplicate flag at an even offset",
    "A duplicate stands for the right-hand node of a last pair, so its offset is odd.",
    <<7, 1, 1, 0, 1>>,
    [],
    refused.("bad_duplicate_offset")
  )
]

failed_vectors = [
  beef.(
    "failed-root-mismatch",
    false,
    "BRC-62",
    ["brc-62", "bitblocks"],
    "A proof pointed at the wrong block",
    "BRC-62's BUMP with its height changed to 813706, whose real header has another root. The subject fails with its ancestor.",
    Beef.encode([%{brc62_bump | height: 813_706}], [
      {brc62_parent.raw, 0},
      {brc62_payment.raw, nil}
    ]),
    [813_706],
    answer.("failed", "ancestor_failed", "beef_v1", payment_id, nil, [
      entry.("failed", "root_mismatch", parent_id, 813_706),
      entry.("failed", "ancestor_failed", payment_id, nil)
    ])
  ),
  beef.(
    "failed-tampered-sibling",
    false,
    "BRC-62",
    ["brc-62", "bitblocks"],
    "A changed hash in the path",
    "BRC-62's example with one sibling at level 0 hashed again. The climb reaches some other root.",
    Beef.encode([tampered_bump], [{brc62_parent.raw, 0}, {brc62_payment.raw, nil}]),
    [814_435],
    answer.("failed", "ancestor_failed", "beef_v1", payment_id, nil, [
      entry.("failed", "root_mismatch", parent_id, 814_435),
      entry.("failed", "ancestor_failed", payment_id, nil)
    ])
  ),
  beef.(
    "failed-tampered-transaction",
    false,
    "BRC-62",
    ["brc-62", "bitblocks"],
    "A changed transaction",
    "BRC-62's parent with its last byte flipped, so it has another txid and isn't a leaf of the BUMP.",
    Beef.encode([brc62_bump], [{tampered_parent, 0}]),
    [814_435],
    answer.("failed", "not_in_bump", "beef_v1", Reader.txid(tampered_parent), nil, [
      entry.("failed", "not_in_bump", Reader.txid(tampered_parent), nil)
    ])
  ),
  beef.(
    "failed-incomplete-path",
    false,
    "BRC-74",
    ["bitblocks"],
    "A path with a node missing",
    "Crafted: three levels, and nothing at offset 1 of level 0 or above to climb with.",
    Beef.encode(
      [
        bump_at.(h_incomplete, [
          [leaf.(0, sha256d.(crafted_lone), true), leaf.(4, filler, false)],
          [],
          []
        ])
      ],
      [{crafted_lone, 0}]
    ),
    [h_incomplete],
    answer.("failed", "incomplete", "beef_v1", Reader.txid(crafted_lone), nil, [
      entry.("failed", "incomplete", Reader.txid(crafted_lone), nil)
    ])
  ),
  beef.(
    "failed-tree-height",
    false,
    "hardening",
    ["bitblocks"],
    "A tree height that doesn't fit the block",
    "Crafted: the root matches, but a block of 1,000 transactions has a tree of height 10, and this BUMP has 1. That shape would let an inner node pose as a leaf.",
    Beef.encode(
      [bump_at.(h_tree, [[leaf.(0, sibling, false), leaf.(1, sha256d.(crafted_pair), true)]])],
      [{crafted_pair, 0}]
    ),
    [h_tree],
    answer.("failed", "tree_height_mismatch", "beef_v1", Reader.txid(crafted_pair), h_tree, [
      entry.("failed", "tree_height_mismatch", Reader.txid(crafted_pair), h_tree)
    ])
  ),
  beef.(
    "failed-offset-past-block",
    false,
    "hardening",
    ["bitblocks"],
    "An offset past the block's last transaction",
    "Crafted: the root matches, but the block has one transaction and this one sits at offset 1.",
    Beef.encode(
      [bump_at.(h_past, [[leaf.(0, sibling, false), leaf.(1, sha256d.(crafted_pair), true)]])],
      [{crafted_pair, 0}]
    ),
    [h_past],
    answer.("failed", "offset_past_block", "beef_v1", Reader.txid(crafted_pair), h_past, [
      entry.("failed", "offset_past_block", Reader.txid(crafted_pair), h_past)
    ])
  ),
  beef.(
    "failed-64-byte-transaction",
    false,
    "hardening",
    ["bitblocks"],
    "A 64-byte transaction",
    "Crafted: 64 bytes is also the preimage of an inner merkle node, so such a transaction could pose as a leaf.",
    Beef.encode([bump_at.(h_64, [[leaf.(0, sha256d.(sixty_four), true)]])], [{sixty_four, 0}]),
    [h_64],
    answer.("failed", "ambiguous_64_byte_tx", "beef_v1", Reader.txid(sixty_four), nil, [
      entry.("failed", "ambiguous_64_byte_tx", Reader.txid(sixty_four), nil)
    ])
  ),
  beef.(
    "unknown-parent-not-included",
    false,
    "BRC-62",
    ["bitblocks"],
    "A transaction whose parent isn't there",
    "Crafted: no BUMP and no parent in the BEEF, so it leads to no proof. BRC-62 asks for the ancestors; a reader can still answer unknown.",
    Beef.encode([], [{crafted_lone, nil}]),
    [],
    answer.("unknown", "no_inputs_in_beef", "beef_v1", Reader.txid(crafted_lone), nil, [
      entry.("unknown", "no_inputs_in_beef", Reader.txid(crafted_lone), nil)
    ])
  ),
  beef.(
    "unknown-coinbase-without-bump",
    false,
    "BRC-62",
    ["bitblocks"],
    "A coinbase with no proof",
    "Crafted: a coinbase has no parents to lead to, so without its own BUMP nothing supports it.",
    Beef.encode([], [{coinbase, nil}]),
    [],
    answer.("unknown", "no_bump", "beef_v1", Reader.txid(coinbase), nil, [
      entry.("unknown", "no_bump", Reader.txid(coinbase), nil)
    ])
  )
]

doc =
  O.new(
    name: "bitblocks-interop-vectors",
    version: "1.0.0",
    status: "draft",
    published: "2026-11-05",
    url: "https://bitblocks.app/interop/vectors/v1.json",
    description:
      "Test vectors for payments that carry their own proof: BEEF V1 (BRC-62), BEEF V2 (BRC-96), Atomic BEEF (BRC-95) and BUMP (BRC-74). Each states what it should do, with where it came from.",
    versioning:
      "Within v1, a vector's id, bytes and expected outcome stay as they are, except to correct a mistake, which the version number and this file will show. New vectors raise the minor version. A change to what outcomes mean gets a new file.",
    claim:
      "These vectors cover inclusion in a block. They say whether a transaction's bytes sit under a merkle root in a header. They don't say a transaction is valid, its scripts pass, its inputs were unspent, a token is genuine or a payment was made.",
    not_checked: ~w(scripts signatures input_amounts double_spends token_validity payment_terms),
    tried_against:
      "One SDK, @bsv/sdk 2.4.0, in a one-off run, and no live wallet. Nothing in this file says any wallet, SDK or project conforms to it or endorses it.",
    how_to_use: [
      "Treat the entries in headers_held as the headers you hold, and no others. Each one is looked up in headers by height.",
      "For a beef vector, decode hex, read it, and compare your answer with expected.",
      "For a bump vector, decode hex, read it as one BUMP with nothing left over, and climb each named txid to the root.",
      "outcome is the result to match. reason is the name Bitblocks uses, so yours may differ."
    ],
    fields:
      O.new(
        valid:
          "true: a conforming sender could produce these bytes. false: deliberately wrong, or short of what a sender owes.",
        basis:
          "The BRC whose rule this vector exercises, or hardening: a stricter reading Bitblocks applies where a spec is silent or leaves room. A reader may differ on a hardening vector and still follow the spec.",
        headers:
          "synthetic: false is a real mainnet header, with its 80 bytes to check for yourself. synthetic: true is a root made up for this kit, for use in this kit only.",
        tx_count:
          "A block's transaction count. It isn't in the 80-byte header, so it comes from outside it."
      ),
    outcomes:
      O.new(
        proven:
          "Its bytes hash to its txid, its BUMP climbs to a root, and that root is the one in a header you rely on at that height.",
        anchored:
          "It has no BUMP, and every input leads, within this BEEF, to proven transactions. It is not itself shown to be in a block.",
        unknown:
          "The checker can't say: no header at that height, or the BEEF lacks what it needs. Never read this as a pass.",
        failed:
          "The evidence is wrong: the root differs from the header, the BUMP reaches no root or can't be that block's, or an ancestor failed.",
        refused: "The bytes can't be read as this format.",
        root: "A BUMP vector: each named txid climbs to this root at this offset."
      ),
    sources: sources,
    headers: headers,
    vectors: valid_vectors ++ refused_vectors ++ failed_vectors
  )

if "--write" in System.argv() do
  path = Path.expand("../priv/data/interop/vectors_v1.json", __DIR__)
  File.write!(path, Jason.encode!(doc, pretty: true) <> "\n")
  IO.puts("wrote #{path}: #{length(doc[:vectors])} vectors")
end

doc
