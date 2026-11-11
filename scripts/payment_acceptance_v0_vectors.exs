# Builds priv/data/interop/payment_acceptance_v0.json: Bitblocks' own
# interop-kit/payment-acceptance/v0 record, BRC-77 signed, with the records a
# reader must refuse (docs/INTEROP_KIT.md).
#
#     MIX_ENV=test mix run --no-start scripts/payment_acceptance_v0_vectors.exs --write
#
# Every input is fixed, and BRC-77 signing is deterministic (RFC 6979), so a run
# writes the same bytes. The key is a test key, made from a public label: it
# signs these vectors and nothing else, and must never hold funds.
# test/bitblocks/interop/payment_acceptance_test.exs evaluates this script and
# compares the result to the file; each refusal's reason is declared by hand.

alias Bitblocks.Interop.{Brc77, Jcs, PaymentAcceptance}
alias Jason.OrderedObject, as: O

hex = &Base.encode16(&1, case: :lower)
sha256 = &:crypto.hash(:sha256, &1)

key_label = "bitblocks payment-acceptance v0 test key: public, never fund it"
privkey = sha256.(key_label)
pubkey = hex.(Brc77.public_key(privkey))
other_label = "bitblocks payment-acceptance v0 other test key: public, never fund it"
other_privkey = sha256.(other_label)
key_id = "bitblocks acceptance test key 01"
32 = byte_size(key_id)

# A made-up testnet payment: three outputs to the receiver, given out of order.
txid_a = hex.(sha256.("bitblocks payment-acceptance v0 test payment a"))
txid_b = hex.(sha256.("bitblocks payment-acceptance v0 test payment b"))

outputs = [
  %{txid: txid_b, vout: 0, satoshis: 1_000},
  %{txid: txid_a, vout: 3, satoshis: 250},
  %{txid: txid_a, vout: 1, satoshis: 4_000}
]

# The terms the receiver stated before payment, salted (step 1 of the pattern).
terms =
  Jcs.encode!(%{
    "amount" => 5_250,
    "payTo" => pubkey,
    "salt" => hex.(sha256.("bitblocks payment-acceptance v0 test terms salt")),
    "unit" => "sats"
  })

record =
  PaymentAcceptance.build(%{
    accepted_by: pubkey,
    network: "bsv:testnet",
    outputs: outputs,
    terms_hash: hex.(sha256.(terms)),
    evidence_hash: nil,
    accepted_at: 1_794_268_800
  })

{:ok, canonical} = PaymentAcceptance.encode(record)
{:ok, signed} = PaymentAcceptance.sign(canonical, privkey, key_id)
envelope = Base.decode64!(signed["signature"])

signed_json = fn body, signature ->
  Jason.encode!(O.new(body: body, signature: signature))
end

resign = fn body -> Base.encode64(Brc77.sign(body, privkey, key_id)) end

refusal = fn id, basis, body, signature, reason ->
  O.new(
    id: id,
    valid: false,
    basis: basis,
    signed: signed_json.(body, signature),
    expected: reason
  )
end

one_byte_changed = String.replace(canonical, "\"satoshis\":250", "\"satoshis\":350")
true = one_byte_changed != canonical

pretty = Jason.encode!(Jason.decode!(canonical), pretty: true)

unknown_field =
  Jcs.encode!(Map.put(record, "payer", "02" <> String.duplicate("ab", 32)))

unsorted =
  canonical
  |> Jason.decode!()
  |> Map.update!("outputs", &Enum.reverse/1)
  |> Jcs.encode!()

missing = Jcs.encode!(Map.delete(record, "termsHash"))

boolean =
  Jcs.encode!(Map.put(record, "evidenceHash", nil))
  |> String.replace("\"evidenceHash\":null", "\"evidenceHash\":false")

other_signed =
  Base.encode64(Brc77.sign(canonical, other_privkey, key_id))

{:ok, other_signer} = Brc77.verify(canonical, Base.decode64!(other_signed))

refusals = [
  refusal.(
    "one-byte-changed",
    "The signed record with one output's satoshis changed after signing",
    one_byte_changed,
    signed["signature"],
    O.new(reason: "signature_fails")
  ),
  refusal.(
    "another-signer",
    "A valid BRC-77 signature over the exact bytes, by a key that is not acceptedBy",
    canonical,
    other_signed,
    O.new(reason: "signer_mismatch", signer: hex.(other_signer))
  ),
  refusal.(
    "not-canonical",
    "The same members, indented: they parse, but aren't the canonical bytes; signed as they are",
    pretty,
    resign.(pretty),
    O.new(reason: "not_canonical")
  ),
  refusal.(
    "unknown-field",
    "A payer field the record doesn't have (v0 names no payer); signed",
    unknown_field,
    resign.(unknown_field),
    O.new(reason: "unknown_field", field: "payer")
  ),
  refusal.(
    "missing-field",
    "Every field is required, null where there's nothing to say; termsHash left out; signed",
    missing,
    resign.(missing),
    O.new(reason: "missing_field", field: "termsHash")
  ),
  refusal.(
    "outputs-unsorted",
    "The outputs in reverse order: v0 sorts them by txid, then vout; signed",
    unsorted,
    resign.(unsorted),
    O.new(reason: "invalid", field: "outputs")
  ),
  refusal.(
    "boolean",
    "A boolean where a hash or null belongs: the restricted set holds none; signed",
    boolean,
    resign.(boolean),
    O.new(reason: "boolean")
  )
]

doc =
  O.new(
    name: "payment_acceptance_v0",
    spec:
      "docs/INTEROP_KIT.md: interop-kit/payment-acceptance/v0, RFC 8785 canonical bytes (strings, integers within ±(2^53 - 1), null, arrays, objects), BRC-77 signed by acceptedBy for anyone, carried as {body, signature}",
    source:
      "generated by scripts/payment_acceptance_v0_vectors.exs with Bitblocks.Interop.PaymentAcceptance; copy, don't re-derive",
    shape: "each vector: id, valid, basis, its inputs, expected",
    test_key:
      O.new(
        warning:
          "A test key from a public label. It signs these vectors only; never send funds to it.",
        label: key_label,
        privkey_hex: hex.(privkey),
        pubkey: pubkey,
        key_id: key_id,
        key_id_base64: Base.encode64(key_id),
        protocol: O.new(protocolID: [2, "message signing"], counterparty: "anyone")
      ),
    acceptance_record: [
      O.new(
        id: "bitblocks-accepts-three-outputs",
        valid: true,
        basis:
          "A made-up testnet payment of three outputs across two txids, given out of order and sorted by txid then vout; termsHash is the SHA-256 of the terms bytes below, evidenceHash null",
        outputs_given:
          Enum.map(outputs, &O.new(txid: &1.txid, vout: &1.vout, satoshis: &1.satoshis)),
        terms: terms,
        record:
          O.new(
            version: record["version"],
            acceptedBy: record["acceptedBy"],
            network: record["network"],
            outputs:
              Enum.map(
                record["outputs"],
                &O.new(txid: &1["txid"], vout: &1["vout"], satoshis: &1["satoshis"])
              ),
            termsHash: record["termsHash"],
            evidenceHash: record["evidenceHash"],
            acceptedAt: record["acceptedAt"]
          ),
        expected:
          O.new(
            canonical: canonical,
            sha256: PaymentAcceptance.hash(canonical),
            envelope_hex: hex.(envelope),
            signed: signed_json.(canonical, signed["signature"])
          )
      )
    ],
    refusals: refusals
  )

if "--write" in System.argv() do
  path = Path.expand("../priv/data/interop/payment_acceptance_v0.json", __DIR__)
  File.write!(path, Jason.encode!(doc, pretty: true) <> "\n")
  IO.puts("wrote #{path}")
end

doc
