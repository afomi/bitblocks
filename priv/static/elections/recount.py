#!/usr/bin/env python3
"""Recount a Bitblocks election from its archive alone, offline.

    python3 recount.py <archive folder> --archive-sha256 <hex from the result record>
    python3 recount.py <archive folder> --result-tx <result tx file>
    python3 recount.py --self-test <election_count_v0.json>

It makes no network calls, and needs nothing but Python 3.8 or later.
In order, it:

  1. checks every file against MANIFEST.sha256, and the manifest's own sha256
     against the archive_sha256 the result record carries;
  2. checks that the headers chain: each names the one before it and hashes
     below its own target;
  3. checks each tx's bytes against its txid, and each BUMP (BRC-74) against
     the merkle root of its block's header;
  4. re-reads every record from the tx bytes: the MAP fields, and the AIP
     signature over every field, which gives the signer's address;
  5. runs the counting rule on what it read;
  6. compares the tally and winners with count.json and the result record.

If anything fails it names the file or tx, prints no tally, and exits 1.

The format and the rule: https://github.com/afomi/bitblocks/blob/develop/docs/ELECTION_DOGFOOD.md
The rule's test vectors: https://bitblocks.app/interop/elections/count/v0.json
This file: https://bitblocks.app/elections/recount.py (MIT licence, as the repository).
"""

import argparse
import base64
import hashlib
import json
import os
import re
import struct
import sys

VERSION = "0.1.0"
DEPTH = 6

if sys.version_info < (3, 8):
    sys.stderr.write("recount.py needs Python 3.8 or later.\n")
    sys.exit(2)


# ---------------------------------------------------------------------------
# Hashes
# ---------------------------------------------------------------------------


def sha256(data):
    return hashlib.sha256(data).digest()


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def sha256d(data):
    return sha256(sha256(data))


def display(internal):
    """A hash in display order (as explorers show it), from internal order."""
    return internal[::-1].hex()


def _ripemd160_pure(message):
    # RIPEMD-160, for Pythons whose OpenSSL leaves it out of hashlib.
    def rol(x, n):
        return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF

    def f(j, x, y, z):
        if j < 16:
            return x ^ y ^ z
        if j < 32:
            return (x & y) | (~x & z)
        if j < 48:
            return (x | ~y) ^ z
        if j < 64:
            return (x & z) | (y & ~z)
        return x ^ (y | ~z)

    k_left = [0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E]
    k_right = [0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000]
    r_left = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
        4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13,
    ]
    r_right = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
        12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11,
    ]
    s_left = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
        9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6,
    ]
    s_right = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
        8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11,
    ]

    h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    padded = message + b"\x80" + b"\x00" * ((55 - len(message)) % 64)
    padded += struct.pack("<Q", (len(message) * 8) & 0xFFFFFFFFFFFFFFFF)

    for block in range(0, len(padded), 64):
        x = struct.unpack("<16I", padded[block : block + 64])
        al, bl, cl, dl, el = h
        ar, br, cr, dr, er = h
        for j in range(80):
            t = (al + f(j, bl, cl, dl) + x[r_left[j]] + k_left[j // 16]) & 0xFFFFFFFF
            t = (rol(t, s_left[j]) + el) & 0xFFFFFFFF
            al, el, dl, cl, bl = el, dl, rol(cl, 10), bl, t
            t = (ar + f(79 - j, br, cr, dr) + x[r_right[j]] + k_right[j // 16]) & 0xFFFFFFFF
            t = (rol(t, s_right[j]) + er) & 0xFFFFFFFF
            ar, er, dr, cr, br = er, dr, rol(cr, 10), br, t
        t = (h[1] + cl + dr) & 0xFFFFFFFF
        h[1] = (h[2] + dl + er) & 0xFFFFFFFF
        h[2] = (h[3] + el + ar) & 0xFFFFFFFF
        h[3] = (h[4] + al + br) & 0xFFFFFFFF
        h[4] = (h[0] + bl + cr) & 0xFFFFFFFF
        h[0] = t

    return struct.pack("<5I", *h)


def ripemd160(data):
    try:
        return hashlib.new("ripemd160", data).digest()
    except (ValueError, TypeError):
        return _ripemd160_pure(data)


def hash160(data):
    return ripemd160(sha256(data))


B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def base58check_decode(text):
    """(version byte, payload) or None."""
    if not isinstance(text, str) or text == "" or any(c not in B58 for c in text):
        return None
    n = 0
    for c in text:
        n = n * 58 + B58.index(c)
    body = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    raw = b"\x00" * (len(text) - len(text.lstrip("1"))) + body
    if len(raw) < 5 or sha256d(raw[:-4])[:4] != raw[-4:]:
        return None
    return raw[0], raw[1:-4]


# ---------------------------------------------------------------------------
# secp256k1: just enough to check a Bitcoin Signed Message signature
# ---------------------------------------------------------------------------

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (
    0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
    0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
)


def _point_add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0]:
        if (a[1] + b[1]) % P == 0:
            return None
        slope = 3 * a[0] * a[0] * pow(2 * a[1], -1, P) % P
    else:
        slope = (b[1] - a[1]) * pow(b[0] - a[0], -1, P) % P
    x = (slope * slope - a[0] - b[0]) % P
    return (x, (slope * (a[0] - x) - a[1]) % P)


def _point_mul(k, point):
    result = None
    while k:
        if k & 1:
            result = _point_add(result, point)
        point = _point_add(point, point)
        k >>= 1
    return result


def _varint(n):
    if n < 0xFD:
        return bytes([n])
    if n <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", n)
    if n <= 0xFFFFFFFF:
        return b"\xfe" + struct.pack("<I", n)
    return b"\xff" + struct.pack("<Q", n)


BSM_PREFIX = b"Bitcoin Signed Message:\n"


def bsm_digests(message):
    """The digests a Bitcoin Signed Message over `message` may be made with.
    They differ only for a message of exactly 253 bytes: Bitcoin frames that
    length as fd fd 00 (as wallets sign), and bsv-ex as the one byte fd (as
    its BSV.Message signs). Bitblocks takes either, so this does too."""
    framed = _varint(len(BSM_PREFIX)) + BSM_PREFIX
    digests = [sha256d(framed + _varint(len(message)) + message)]
    if len(message) == 253:
        digests.append(sha256d(framed + b"\xfd" + message))
    return digests


def recover_pubkey(digest, signature):
    """The public key (bytes, compressed or not as the signature says) that
    made a 65-byte compact signature over `digest`, or None."""
    if len(signature) != 65:
        return None
    header = signature[0]
    compressed = header - 31 >= 0
    recid = header - 31 if compressed else header - 27
    if recid not in (0, 1, 2, 3):
        return None
    r = int.from_bytes(signature[1:33], "big")
    s = int.from_bytes(signature[33:], "big")
    if not (0 < r < N and 0 < s < N):
        return None
    x = r + (recid >> 1) * N
    if x >= P:
        return None
    alpha = (pow(x, 3, P) + 7) % P
    beta = pow(alpha, (P + 1) // 4, P)
    if beta * beta % P != alpha:
        return None
    y = beta if beta % 2 == (recid & 1) else P - beta
    e = int.from_bytes(digest, "big")
    r_inv = pow(r, -1, N)
    q = _point_add(_point_mul(s * r_inv % N, (x, y)), _point_mul((-e * r_inv) % N, G))
    if q is None:
        return None
    # And the plain ECDSA check with that key.
    w = pow(s, -1, N)
    check = _point_add(_point_mul(e * w % N, G), _point_mul(r * w % N, q))
    if check is None or check[0] % N != r:
        return None
    if compressed:
        return bytes([2 + (q[1] & 1)]) + q[0].to_bytes(32, "big")
    return b"\x04" + q[0].to_bytes(32, "big") + q[1].to_bytes(32, "big")


def signature_checks(message, address, signature):
    """True when `signature` (raw 65 bytes, or base64 of them) over `message`
    was made by the key behind P2PKH `address` (mainnet or testnet)."""
    decoded = base58check_decode(address.decode("utf-8", "replace"))
    if decoded is None or decoded[0] not in (0x00, 0x6F) or len(decoded[1]) != 20:
        return False
    if len(signature) == 65:
        raw = signature
    else:
        try:
            raw = base64.b64decode(signature, validate=True)
        except (ValueError, TypeError):
            return False
        if len(raw) != 65:
            return False
    for digest in bsm_digests(message):
        pubkey = recover_pubkey(digest, raw)
        if pubkey is not None and hash160(pubkey) == decoded[1]:
            return True
    return False


# ---------------------------------------------------------------------------
# Transactions and scripts
# ---------------------------------------------------------------------------


class Op:
    """An opcode in a script (a push is plain bytes)."""

    __slots__ = ("code",)

    def __init__(self, code):
        self.code = code

    def __eq__(self, other):
        return isinstance(other, Op) and other.code == self.code

    def __hash__(self):
        return hash(("op", self.code))


OP_0 = 0x00
OP_RETURN = 0x6A
# The opcodes with a name; any other byte ends the script's parse, its
# remainder kept as one push, as Bitblocks reads it.
NAMED_OPS = set(range(0x00, 0xBA)) | {0xF9, 0xFA, 0xFB, 0xFD, 0xFE, 0xFF}


def read_varint(data, i):
    if i >= len(data):
        raise ValueError("truncated")
    first = data[i]
    if first < 0xFD:
        return first, i + 1
    size = {0xFD: 2, 0xFE: 4, 0xFF: 8}[first]
    if i + 1 + size > len(data):
        raise ValueError("truncated")
    return int.from_bytes(data[i + 1 : i + 1 + size], "little"), i + 1 + size


def parse_tx(data):
    """{'outputs': [script bytes, ...]}; raises ValueError if it isn't a tx."""
    if len(data) < 4:
        raise ValueError("truncated")
    i = 4
    count, i = read_varint(data, i)
    for _ in range(count):
        i += 36
        length, i = read_varint(data, i)
        i += length + 4
        if i > len(data):
            raise ValueError("truncated")
    count, i = read_varint(data, i)
    outputs = []
    for _ in range(count):
        i += 8
        length, i = read_varint(data, i)
        if i + length > len(data):
            raise ValueError("truncated")
        outputs.append(data[i : i + length])
        i += length
    if len(data) - i != 4:
        raise ValueError("not one tx")
    return {"outputs": outputs}


def script_chunks(script):
    chunks = []
    i = 0
    while i < len(script):
        op = script[i]
        if 1 <= op <= 75:
            if i + 1 + op <= len(script):
                chunks.append(script[i + 1 : i + 1 + op])
                i += 1 + op
                continue
            chunks.append(script[i:])
            break
        if op in (0x4C, 0x4D, 0x4E):
            size = {0x4C: 1, 0x4D: 2, 0x4E: 4}[op]
            if i + 1 + size <= len(script):
                n = int.from_bytes(script[i + 1 : i + 1 + size], "little")
                start = i + 1 + size
                if start + n <= len(script):
                    chunks.append(script[start : start + n])
                    i = start + n
                    continue
            chunks.append(script[i:])
            break
        if op in NAMED_OPS:
            chunks.append(Op(op))
            i += 1
            continue
        chunks.append(script[i:])
        break
    return chunks


# ---------------------------------------------------------------------------
# AIP and the election records
# ---------------------------------------------------------------------------

B_PREFIX = b"19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"
MAP_PREFIX = b"1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"
AIP_PREFIX = b"15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva"
PIPE = b"|"

TYPES = {
    b"election_v1": "election",
    b"roll_v1": "roll",
    b"ballot_v1": "ballot",
    b"result_v1": "result",
}

INTEGER = re.compile(r"(0|[1-9][0-9]*)")
OUTPOINT = re.compile(r"[0-9a-f]{64}\.(0|[1-9][0-9]*)")
HEX64 = re.compile(r"[0-9a-f]{64}")
SIGNED_INDEX = re.compile(r"[+-]?[0-9]+")


class NotARecord(Exception):
    pass


def _aip_indexes(cells):
    if not cells:
        return None
    indexes = []
    for cell in cells:
        if not isinstance(cell, bytes):
            continue
        if len(cell) == 1 and not (0x30 <= cell[0] <= 0x39):
            indexes.append(cell[0])
            continue
        text = cell.decode("latin-1")
        match = re.match(r"[+-]?[0-9]+", text)
        if match and match.end() == len(text) and int(text) >= 0:
            indexes.append(int(text))
    return indexes


def aip_signatures(data):
    """Each AIP section in `data` (the pushes after OP_RETURN, with OP_RETURN
    first): {'address', 'indexes', 'valid'}."""
    while data and isinstance(data[0], Op) and data[0].code in (OP_0, OP_RETURN):
        data = data[1:]
    signatures = []
    for i, cell in enumerate(data):
        if cell != AIP_PREFIX:
            continue
        left, rest = data[:i], data[i + 1 :]
        if len(rest) < 3 or not all(isinstance(c, bytes) for c in rest[:3]):
            signatures.append({"address": None, "indexes": None, "valid": False})
            continue
        algorithm, address, signature = rest[:3]
        indexes = _aip_indexes(rest[3:])
        fields = [b"\x6a"] + [c if isinstance(c, bytes) else b"" for c in left]
        if indexes is None:
            message = b"".join(fields)
        else:
            message = b"".join(fields[j] if j < len(fields) else b"" for j in indexes)
        try:
            valid = algorithm == b"BITCOIN_ECDSA" and signature_checks(message, address, signature)
        except Exception:
            valid = False
        signatures.append({"address": address, "indexes": indexes, "valid": valid})
    return signatures


def _segments(data):
    segments, current = [], []
    for i, cell in enumerate(data):
        if cell == PIPE:
            segments.append(current)
            current = []
        else:
            current.append((cell, i))
    segments.append(current)
    return [
        {"prefix": s[0][0], "cells": [c for c, _ in s], "positions": [p for _, p in s]}
        for s in segments
        if s
    ]


def _text(keys, key):
    value = keys.get(key.encode())
    if not isinstance(value, bytes):
        raise NotARecord("missing field %s" % key)
    try:
        return value.decode("utf-8")
    except UnicodeDecodeError:
        raise NotARecord("%s is not UTF-8" % key)


def _integer(keys, key):
    value = _text(keys, key)
    if not INTEGER.fullmatch(value):
        raise NotARecord("%s must be decimal ASCII with no leading zeros" % key)
    return int(value)


def _json(text):
    def refuse(name):
        raise ValueError(name)

    return json.loads(text, parse_constant=refuse)


def _json_list(keys, key):
    try:
        value = _json(_text(keys, key))
    except ValueError:
        raise NotARecord("%s must be one JSON array" % key)
    if not isinstance(value, list):
        raise NotARecord("%s must be one JSON array" % key)
    return value


def _outpoint(keys, key):
    value = _text(keys, key)
    if not OUTPOINT.fullmatch(value):
        raise NotARecord("%s must be an outpoint: <txid>.<vout>" % key)
    return value


def _hex64(keys, key):
    value = _text(keys, key)
    if not HEX64.fullmatch(value):
        raise NotARecord("%s must be 64 lowercase hex characters" % key)
    return value


def parse_record(script, vout, app):
    """The election record in one output's script, as Bitblocks reads it:
    {'kind', 'vout', 'signer', 'signature_error', 'fields'}. Raises
    NotARecord saying why it isn't one."""
    chunks = script_chunks(script)
    at = next((i for i, c in enumerate(chunks) if c == Op(OP_RETURN)), None)
    if at is None:
        raise NotARecord("not a data output")
    data = chunks[at + 1 :]
    segments = _segments(data)

    map_segment = next((s for s in segments if s["prefix"] == MAP_PREFIX), None)
    if map_segment is None:
        raise NotARecord("no MAP")
    cells = map_segment["cells"]
    if len(cells) < 2 or cells[1] != b"SET":
        raise NotARecord("MAP is not a SET")
    pairs = cells[2:]
    if len(pairs) % 2 == 1 or not all(isinstance(c, bytes) for c in pairs):
        raise NotARecord("MAP has an odd field")
    keys = {}
    for k, v in zip(pairs[0::2], pairs[1::2]):
        if k in keys:
            raise NotARecord("MAP repeats %r" % k)
        keys[k] = v
    if keys.get(b"app") != app.encode():
        raise NotARecord("another app")
    kind = TYPES.get(keys.get(b"type"))
    if kind is None:
        raise NotARecord("unknown type")

    # The first AIP that checks and covers every field of the B and MAP
    # segments. AIP numbers fields from 0 (OP_RETURN): data position p is p + 1.
    covered = [
        p + 1 for s in segments if s["prefix"] in (B_PREFIX, MAP_PREFIX) for p in s["positions"]
    ]
    signatures = aip_signatures([Op(OP_RETURN)] + data)
    valid = [s for s in signatures if s["valid"] and isinstance(s["address"], bytes)]
    covering = next(
        (s for s in valid if s["indexes"] is None or all(c in s["indexes"] for c in covered)),
        None,
    )
    if covering:
        signer, signature_error = covering["address"].decode("utf-8", "replace"), None
    elif not signatures:
        signer, signature_error = None, "no_signature"
    elif valid:
        signer, signature_error = None, "signature_does_not_cover_fields"
    else:
        signer, signature_error = None, "invalid_signature"

    if kind != "ballot" and signer is None:
        raise NotARecord("its signature doesn't count (%s)" % signature_error)

    if kind == "election":
        fields = {
            "name": _text(keys, "name"),
            "number_elected": _integer(keys, "number_elected"),
            "candidates": _json_list(keys, "candidates"),
            "opens_at_height": _integer(keys, "opens_at_height"),
            "closes_at_height": _integer(keys, "closes_at_height"),
            "roll": _outpoint(keys, "roll"),
            "roll_sha256": _hex64(keys, "roll_sha256"),
        }
        if b"votes_allowed" in keys:
            fields["votes_allowed"] = _integer(keys, "votes_allowed")
    elif kind == "roll":
        b_segment = next((s for s in segments if s["prefix"] == B_PREFIX), None)
        if b_segment is None or len(b_segment["cells"]) < 2 or not isinstance(
            b_segment["cells"][1], bytes
        ):
            raise NotARecord("no roll file")
        content = b_segment["cells"][1]
        try:
            members = _json(content.decode("utf-8"))["members"]
            if not isinstance(members, list):
                raise TypeError
        except (ValueError, TypeError, KeyError):
            raise NotARecord('the roll file must be JSON {"members": [...]}')
        fields = {"members": members, "content": content, "sha256": sha256_hex(content)}
    elif kind == "ballot":
        fields = {"election": _outpoint(keys, "election"), "choices": None}
        raw = keys.get(b"choices")
        if isinstance(raw, bytes):
            try:
                fields["choices"] = _json(raw.decode("utf-8"))
            except ValueError:
                fields["choices"] = raw.decode("utf-8", "replace")
    else:
        fields = {
            "election": _outpoint(keys, "election"),
            "archive_sha256": _hex64(keys, "archive_sha256"),
            "closes_at_height": _integer(keys, "closes_at_height"),
            "close_block_hash": _hex64(keys, "close_block_hash"),
        }

    return {
        "kind": kind,
        "vout": vout,
        "signer": signer,
        "signature_error": signature_error,
        "fields": fields,
    }


def tx_records(tx_bytes, app):
    """Every election record in a tx, in output order."""
    records = []
    for vout, script in enumerate(parse_tx(tx_bytes)["outputs"]):
        try:
            records.append(parse_record(script, vout, app))
        except NotARecord:
            pass
    return records


# ---------------------------------------------------------------------------
# BUMP (BRC-74) and headers
# ---------------------------------------------------------------------------


def parse_bump(data):
    """{'height', 'path': [[{'offset', 'hash', 'txid', 'duplicate'}]]};
    raises ValueError."""
    height, i = read_varint(data, 0)
    if i >= len(data) or not 1 <= data[i] <= 64:
        raise ValueError("tree height out of range")
    tree_height = data[i]
    i += 1
    path = []
    for level in range(tree_height):
        count, i = read_varint(data, i)
        if level == 0 and count == 0:
            raise ValueError("empty level")
        leaves = []
        for _ in range(count):
            offset, i = read_varint(data, i)
            if i >= len(data):
                raise ValueError("truncated")
            flag = data[i]
            i += 1
            if flag == 1:
                leaves.append({"offset": offset, "hash": None, "txid": False, "duplicate": True})
            elif flag in (0, 2):
                if i + 32 > len(data):
                    raise ValueError("truncated")
                leaves.append(
                    {"offset": offset, "hash": data[i : i + 32], "txid": flag == 2, "duplicate": False}
                )
                i += 32
            else:
                raise ValueError("bad leaf flag")
        offsets = [leaf["offset"] for leaf in leaves]
        if any(o >= 1 << (tree_height - level) for o in offsets):
            raise ValueError("offset out of range")
        if len(set(offsets)) != len(offsets):
            raise ValueError("duplicate offset")
        if any(leaf["duplicate"] and leaf["offset"] % 2 == 0 for leaf in leaves):
            raise ValueError("bad duplicate offset")
        path.append(leaves)
    if i != len(data):
        raise ValueError("trailing bytes")
    return {"height": height, "path": path}


def bump_root(bump, txid):
    """(root in display hex, the txid's offset), or raises ValueError."""
    nodes, implied = {}, {}
    for level, leaves in enumerate(bump["path"]):
        at_level = dict(implied)
        for leaf in leaves:
            at_level[leaf["offset"]] = "dup" if leaf["duplicate"] else leaf["hash"]
        for offset, node in at_level.items():
            nodes[(level, offset)] = node
        implied = {}
        for offset, left in at_level.items():
            if offset % 2 == 0 and isinstance(left, bytes) and (offset + 1) in at_level:
                right = at_level[offset + 1]
                implied[offset >> 1] = sha256d(left + (left if right == "dup" else right))

    level_zero = bump["path"][0]
    offsets = {}
    for leaf in sorted(
        (leaf for leaf in level_zero if not leaf["duplicate"]), key=lambda leaf: -leaf["offset"]
    ):
        offsets[leaf["hash"]] = leaf["offset"]

    node = bytes.fromhex(txid)[::-1]
    if node not in offsets:
        raise ValueError("the txid is not in its BUMP")
    offset = start = offsets[node]
    levels = len(bump["path"])
    if levels == 1 and len(level_zero) == 1:
        return display(node), start
    for level in range(levels):
        sibling = nodes.get((level, offset ^ 1))
        if sibling is None:
            raise ValueError("the BUMP is missing a node")
        if sibling == "dup":
            pair = node + node
        elif offset & 1 == 0:
            pair = node + sibling
        else:
            pair = sibling + node
        node = sha256d(pair)
        offset >>= 1
    return display(node), start


def header_target(bits):
    exponent, mantissa = bits >> 24, bits & 0x7FFFFF
    if exponent <= 3:
        return mantissa >> (8 * (3 - exponent))
    return mantissa << (8 * (exponent - 3))


# The easiest target mainnet allows (difficulty 1).
MAINNET_LIMIT = header_target(0x1D00FFFF)


# ---------------------------------------------------------------------------
# The counting rule (docs/ELECTION_DOGFOOD.md, "The counting rule")
# ---------------------------------------------------------------------------

RULES = [
    "other_election",
    "no_signature",
    "not_on_roll",
    "unconfirmed",
    "before_open",
    "after_close",
    "malformed_choices",
    "too_many_choices",
    "duplicate_choice",
    "unknown_candidate",
    "replaced",
]

RULE_TEXT = {
    "other_election": "it names a different election",
    "no_signature": "no AIP signature checked",
    "not_on_roll": "its signer isn't on the roll",
    "unconfirmed": "it isn't in a block",
    "before_open": "its block is below opens_at_height",
    "after_close": "its block is above closes_at_height",
    "malformed_choices": "choices isn't a list of strings",
    "too_many_choices": "it names more than votes_allowed candidates",
    "duplicate_choice": "it names one candidate twice",
    "unknown_candidate": "it names an id not on the election's list",
    "replaced": "the same signer has a later ballot that passed every other rule",
}

CANDIDATE_ID = re.compile(r"[a-z0-9-]+")


class Refused(Exception):
    def __init__(self, kind, detail):
        Exception.__init__(self, "%s: %s" % (kind, detail))
        self.kind = kind
        self.detail = detail


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _height(value):
    return _is_int(value) and value >= 0


def _confirms_before(record, opens):
    if "height" not in record or record["height"] is None:
        return True
    return _height(record["height"]) and record["height"] < opens


def _str(value):
    return isinstance(value, str)


def _check_election(e):
    def refuse(detail):
        raise Refused("invalid_election", detail)

    if not isinstance(e, dict):
        refuse("election must be a map")
    candidates = e.get("candidates")
    ids = [c.get("id") if isinstance(c, dict) else False for c in candidates] if isinstance(
        candidates, list
    ) else []
    if not (_str(e.get("election")) and OUTPOINT.fullmatch(e["election"])):
        refuse("election must be an outpoint: <txid>.<vout>, lowercase hex and a decimal vout")
    if not (_is_int(e.get("number_elected")) and e["number_elected"] > 0):
        refuse("number_elected must be a positive integer")
    if "votes_allowed" in e and not (_is_int(e["votes_allowed"]) and e["votes_allowed"] > 0):
        refuse("votes_allowed, when given, must be a positive integer")
    if not isinstance(candidates, list) or not all(_str(i) for i in ids):
        refuse("candidates must be a list, each with a string id")
    if not all(CANDIDATE_ID.fullmatch(i) for i in ids):
        refuse("candidate ids must be one or more of a-z, 0-9 and -")
    if len(set(ids)) != len(ids):
        refuse("candidate ids must be unique")
    if not (_str(e.get("roll")) and OUTPOINT.fullmatch(e["roll"])):
        refuse("roll must be the roll file's outpoint: <txid>.<vout>")
    if not (_str(e.get("roll_sha256")) and HEX64.fullmatch(e["roll_sha256"])):
        refuse("roll_sha256 must be 64 lowercase hex characters")
    if not (_height(e.get("opens_at_height")) and _height(e.get("closes_at_height"))):
        refuse("opens_at_height and closes_at_height must be non-negative integers")
    if e["closes_at_height"] < e["opens_at_height"]:
        refuse("closes_at_height is before opens_at_height")
    if not _confirms_before(e, e["opens_at_height"]):
        refuse("the election record must confirm below opens_at_height")


def _check_roll(roll, opens):
    def refuse(detail):
        raise Refused("invalid_roll", detail)

    if not isinstance(roll, dict) or not isinstance(roll.get("members"), list):
        refuse("roll must be a map with members")
    members = roll["members"]
    if not all(_str(m) for m in members):
        refuse("members must be strings")
    if len(set(members)) != len(members):
        refuse("members must be unique")
    if sorted(members) != members:
        refuse("members must be sorted")
    if not _confirms_before(roll, opens):
        refuse("the roll must confirm below opens_at_height")
    return set(members)


def _check_ballots(ballots):
    def refuse(detail):
        raise Refused("invalid_ballot", detail)

    if not isinstance(ballots, list):
        refuse("ballots must be a list")
    txids, slots = set(), set()
    for b in ballots:
        if not isinstance(b, dict) or not _str(b.get("txid")):
            refuse("each ballot needs a string txid")
        if b.get("height") is not None:
            if not _height(b["height"]):
                refuse("height must be a non-negative integer or null")
            if not _height(b.get("position")):
                refuse("a confirmed ballot needs a non-negative position")
        if b["txid"] in txids:
            refuse("txid appears twice")
        slot = (b.get("height"), b.get("position"))
        if b.get("height") is not None and slot in slots:
            refuse("another ballot has this height and position")
        txids.add(b["txid"])
        slots.add(slot)


def _order_key(b):
    if b.get("height") is None:
        return (1, 0, 0, b["txid"])
    return (0, b["height"], b["position"], b["txid"])


def lot(close_block_hash, candidate_id):
    return sha256_hex((close_block_hash.lower() + ":" + candidate_id).encode("utf-8"))


def count(election, roll, ballots, close_block_hash=None):
    """The counting rule, as Bitblocks.Elections.Count.count/4 runs it.
    Raises Refused for an input that can't be a real election."""
    _check_election(election)
    members = _check_roll(roll, election["opens_at_height"])
    _check_ballots(ballots)

    candidate_ids = [c["id"] for c in election["candidates"]]
    known = set(candidate_ids)
    votes_allowed = election.get("votes_allowed") or election["number_elected"]

    def first_failure(b):
        choices = b.get("choices")
        if b.get("election") != election["election"]:
            return "other_election"
        if not _str(b.get("signer")):
            return "no_signature"
        if b["signer"] not in members:
            return "not_on_roll"
        if b.get("height") is None:
            return "unconfirmed"
        if b["height"] < election["opens_at_height"]:
            return "before_open"
        if b["height"] > election["closes_at_height"]:
            return "after_close"
        if not (isinstance(choices, list) and all(_str(c) for c in choices)):
            return "malformed_choices"
        if len(choices) > votes_allowed:
            return "too_many_choices"
        if len(set(choices)) != len(choices):
            return "duplicate_choice"
        if not all(c in known for c in choices):
            return "unknown_candidate"
        return None

    judged = [(b, first_failure(b)) for b in sorted(ballots, key=_order_key)]
    latest = {}
    for b, rule in judged:
        if rule is None:
            latest[b["signer"]] = b["txid"]

    results = []
    for b, rule in judged:
        if rule is None and latest[b["signer"]] == b["txid"]:
            results.append({"txid": b["txid"], "counted": True, "rule": None, "replaced_by": None})
        elif rule is None:
            results.append(
                {
                    "txid": b["txid"],
                    "counted": False,
                    "rule": "replaced",
                    "replaced_by": latest[b["signer"]],
                }
            )
        else:
            results.append({"txid": b["txid"], "counted": False, "rule": rule, "replaced_by": None})

    counted_txids = {r["txid"] for r in results if r["counted"]}
    votes = {c: 0 for c in candidate_ids}
    for b, rule in judged:
        if rule is None and b["txid"] in counted_txids:
            for choice in b["choices"]:
                votes[choice] += 1

    tally = [{"candidate": c, "votes": votes[c]} for c in candidate_ids]
    winners, undecided = _winners(tally, election["number_elected"], close_block_hash)

    return {
        "election": election["election"],
        "ballots": results,
        "counted": len(counted_txids),
        "not_counted": len(results) - len(counted_txids),
        "tally": tally,
        "winners": winners,
        "undecided": undecided,
    }


def _winners(tally, seats, close_block_hash):
    with_votes = sorted((t for t in tally if t["votes"] > 0), key=lambda t: -t["votes"])
    groups = []
    for t in with_votes:
        if groups and groups[-1][0]["votes"] == t["votes"]:
            groups[-1].append(t)
        else:
            groups.append([t])
    won = []
    for group in groups:
        left = seats - len(won)
        ids = [t["candidate"] for t in group]
        if left == 0:
            break
        if len(ids) <= left:
            won += ids
        elif _str(close_block_hash):
            won += sorted(ids, key=lambda i: lot(close_block_hash, i))[:left]
            break
        else:
            return won, {"seats": left, "tied": ids}
    return won, None


# ---------------------------------------------------------------------------
# The archive
# ---------------------------------------------------------------------------


class Failed(Exception):
    """The archive didn't check out: each problem names its file or tx."""

    def __init__(self, problems):
        Exception.__init__(self, "; ".join(problems))
        self.problems = problems


def say(text=""):
    sys.stdout.write(text + "\n")


def _read(folder, path):
    with open(os.path.join(folder, *path.split("/")), "rb") as handle:
        return handle.read()


def check_manifest(folder, archive_sha256):
    """Step 1. The files by path, every one checked against the manifest."""
    problems = []
    try:
        manifest = _read(folder, "MANIFEST.sha256")
    except OSError:
        raise Failed(["MANIFEST.sha256 is missing, so nothing in the folder can be checked."])

    actual = sha256_hex(manifest)
    if archive_sha256 is not None and actual != archive_sha256:
        problems.append(
            "MANIFEST.sha256 hashes to %s, but the result record's archive_sha256 is %s: "
            "this isn't the archive the result was published for." % (actual, archive_sha256)
        )

    files = {}
    lines = manifest.decode("utf-8", "replace").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for number, line in enumerate(lines, 1):
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._/-]+)", line)
        path = match and match.group(2)
        if not match or path.startswith("/") or ".." in path.split("/") or path in files:
            problems.append("MANIFEST.sha256 line %d isn't '<sha256>  <path>': %r" % (number, line))
            continue
        try:
            data = _read(folder, path)
        except OSError:
            problems.append("%s is listed in MANIFEST.sha256 but missing from the folder." % path)
            continue
        if sha256_hex(data) != match.group(1):
            problems.append(
                "%s doesn't match MANIFEST.sha256: it hashes to %s, the manifest says %s."
                % (path, sha256_hex(data), match.group(1))
            )
        files[path] = data
    if [line.split("  ", 1)[-1] for line in lines] != sorted(line.split("  ", 1)[-1] for line in lines):
        problems.append("MANIFEST.sha256 isn't sorted by path.")
    return files, actual, problems


def _need(files, path, problems):
    if path not in files:
        problems.append("%s is not in the archive (or not listed in MANIFEST.sha256)." % path)
        return None
    return files[path]


def check_headers(files, index, problems):
    """Step 2. {height: header bytes}, after checking the chain."""
    raw = _need(files, "headers.bin", problems)
    meta = index.get("headers") or {}
    start = meta.get("from_height")
    if raw is None or not _height(start):
        if raw is not None:
            problems.append("archive.json doesn't say the height headers.bin starts at.")
        return {}
    if len(raw) % 80 != 0 or not raw:
        problems.append("headers.bin is %d bytes, not a whole number of 80-byte headers." % len(raw))
        return {}
    headers = [raw[i : i + 80] for i in range(0, len(raw), 80)]
    by_height = {}
    previous = None
    for offset, header in enumerate(headers):
        height = start + offset
        digest = sha256d(header)
        bits = struct.unpack("<I", header[72:76])[0]
        if int.from_bytes(digest, "little") > header_target(bits):
            problems.append(
                "headers.bin: the header at height %d (%s) doesn't meet its own target."
                % (height, display(digest))
            )
        if previous is not None and header[4:36] != previous:
            problems.append(
                "headers.bin: the header at height %d doesn't name the one at height %d "
                "as its parent, so the headers don't chain." % (height, height - 1)
            )
        previous = digest
        by_height[height] = header
    if meta.get("count") not in (None, len(headers)):
        problems.append(
            "headers.bin holds %d headers, but archive.json says %s." % (len(headers), meta.get("count"))
        )
    return by_height


def header_hash(header):
    return display(sha256d(header))


def header_root(header):
    return display(header[36:68])


def check_txs_and_proofs(files, index, headers, problems):
    """Step 3. {txid: (height, position)} for each record a BUMP places."""
    placed = {}
    records = index.get("records")
    if not isinstance(records, list):
        problems.append("archive.json lists no records.")
        return placed
    for record in records:
        txid = record.get("txid") if isinstance(record, dict) else None
        if not (_str(txid) and HEX64.fullmatch(txid)):
            problems.append("archive.json lists a record without a txid: %r" % (record,))
            continue
        tx_path = "txs/%s.bin" % txid
        data = _need(files, tx_path, problems)
        if data is not None and display(sha256d(data)) != txid:
            problems.append(
                "tx %s: %s hashes to %s, not its txid, so its bytes were changed."
                % (txid, tx_path, display(sha256d(data)))
            )
        proof_path = "proofs/%s.bump" % txid
        if record.get("proof") is None:
            if record.get("height") is not None:
                problems.append(
                    "tx %s: archive.json places it at height %s but gives no proof."
                    % (txid, record.get("height"))
                )
            continue
        if record.get("proof") != proof_path:
            problems.append("tx %s: its proof should be %s." % (txid, proof_path))
            continue
        bump_bytes = _need(files, proof_path, problems)
        if bump_bytes is None:
            problems.append("tx %s: its proof %s is missing, so it can't be placed in a block." % (txid, proof_path))
            continue
        try:
            bump = parse_bump(bump_bytes)
            root, position = bump_root(bump, txid)
        except ValueError as error:
            problems.append("tx %s: %s doesn't prove it: %s." % (txid, proof_path, error))
            continue
        header = headers.get(bump["height"])
        if header is None:
            problems.append(
                "tx %s: %s is for height %d, which has no header in headers.bin."
                % (txid, proof_path, bump["height"])
            )
            continue
        if root != header_root(header):
            problems.append(
                "tx %s: %s climbs to merkle root %s, but the header at height %d has %s."
                % (txid, proof_path, root, bump["height"], header_root(header))
            )
            continue
        if record.get("height") != bump["height"] or record.get("position") != position:
            problems.append(
                "tx %s: archive.json says height %s, position %s; its proof says height %d, position %d."
                % (txid, record.get("height"), record.get("position"), bump["height"], position)
            )
        if record.get("block_hash") != header_hash(header):
            problems.append(
                "tx %s: archive.json names block %s, but the header at height %d is %s."
                % (txid, record.get("block_hash"), bump["height"], header_hash(header))
            )
        placed[txid] = (bump["height"], position)
    return placed


def read_records(files, index, placed, headers, problems):
    """Step 4. The count's input, rebuilt from the tx bytes alone."""
    app = index.get("app")
    election_id = index.get("election")
    if not _str(app) or not (_str(election_id) and OUTPOINT.fullmatch(election_id)):
        problems.append("archive.json doesn't name the election's outpoint and app.")
        return None

    def record_at(entry, kind):
        txid, vout = entry["txid"], entry.get("vout")
        if not _is_int(vout) or vout < 0:
            problems.append("tx %s: archive.json gives no output index." % txid)
            return None
        try:
            outputs = parse_tx(files["txs/%s.bin" % txid])["outputs"]
        except (KeyError, ValueError):
            problems.append("tx %s: txs/%s.bin isn't a transaction." % (txid, txid))
            return None
        if vout >= len(outputs):
            problems.append("tx %s has no output %d." % (txid, vout))
            return None
        try:
            parsed = parse_record(outputs[vout], vout, app)
        except NotARecord as why:
            problems.append("tx %s output %d isn't a %s record: %s." % (txid, vout, kind, why))
            return None
        if parsed["kind"] != kind:
            problems.append("tx %s output %d is a %s record, not a %s." % (txid, vout, parsed["kind"], kind))
            return None
        if entry.get("signer") != parsed["signer"]:
            problems.append(
                "tx %s: archive.json says signer %s, but the signature gives %s."
                % (txid, entry.get("signer"), parsed["signer"])
            )
        return parsed

    def height_of(txid):
        return placed.get(txid, (None, None))

    records = [r for r in index.get("records") or [] if isinstance(r, dict)]
    election_txid, election_vout = election_id.split(".")
    elections = [
        r for r in records if r.get("kind") == "election" and r.get("txid") == election_txid
    ]
    if len(elections) != 1 or elections[0].get("vout") != int(election_vout):
        problems.append("archive.json doesn't list the election record %s once." % election_id)
        return None
    election = record_at(elections[0], "election")
    if election is None:
        return None
    if height_of(election_txid)[0] is None:
        problems.append("tx %s: the election record has no proof that it confirmed." % election_txid)
        return None
    administrator = election["signer"]
    if index.get("administrator") != administrator:
        problems.append(
            "archive.json names administrator %s, but the election record is signed by %s."
            % (index.get("administrator"), administrator)
        )

    roll_id = election["fields"]["roll"]
    roll_txid, roll_vout = roll_id.split(".")
    rolls = [r for r in records if r.get("kind") == "roll" and r.get("txid") == roll_txid]
    if len(rolls) != 1 or rolls[0].get("vout") != int(roll_vout):
        problems.append("archive.json doesn't list the roll %s once." % roll_id)
        return None
    roll = record_at(rolls[0], "roll")
    if roll is None:
        return None
    if height_of(roll_txid)[0] is None:
        problems.append("tx %s: the roll has no proof that it confirmed." % roll_txid)
        return None
    if roll["fields"]["sha256"] != election["fields"]["roll_sha256"]:
        problems.append(
            "tx %s: the roll file hashes to %s, but the election's roll_sha256 is %s."
            % (roll_txid, roll["fields"]["sha256"], election["fields"]["roll_sha256"])
        )
    if roll["signer"] != administrator:
        problems.append(
            "tx %s: the roll is signed by %s, not the election's administrator %s."
            % (roll_txid, roll["signer"], administrator)
        )
    roll_file = files.get("roll.json")
    if roll_file is None or roll_file != roll["fields"]["content"]:
        problems.append("roll.json isn't the roll file's exact bytes on chain (tx %s)." % roll_txid)

    ballots = []
    for entry in records:
        if entry.get("kind") != "ballot":
            continue
        parsed = record_at(entry, "ballot")
        if parsed is None:
            continue
        if parsed["fields"]["election"] != election_id:
            problems.append("tx %s: the ballot names election %s." % (entry["txid"], parsed["fields"]["election"]))
            continue
        # The tx's first ballot naming this election is the one that counts.
        first = next(
            r
            for r in tx_records(files["txs/%s.bin" % entry["txid"]], app)
            if r["kind"] == "ballot" and r["fields"]["election"] == election_id
        )
        if first["vout"] != parsed["vout"]:
            problems.append(
                "tx %s: its first ballot for this election is output %d, not %d."
                % (entry["txid"], first["vout"], parsed["vout"])
            )
        height, position = height_of(entry["txid"])
        ballots.append(
            {
                "txid": entry["txid"],
                "election": parsed["fields"]["election"],
                "height": height,
                "position": position,
                "signer": parsed["signer"],
                "choices": parsed["fields"]["choices"],
            }
        )

    closes = election["fields"]["closes_at_height"]
    to_height = closes + DEPTH
    if max(headers or [-1]) < to_height:
        problems.append(
            "headers.bin stops at height %d, before closes_at_height + %d (%d), "
            "so the archive can't show the close was buried." % (max(headers or [-1]), DEPTH, to_height)
        )
    close_header = headers.get(closes)
    election_input = dict(election["fields"])
    election_input["election"] = election_id
    election_input["height"] = height_of(election_txid)[0]

    return {
        "election": election_input,
        "roll": {"members": roll["fields"]["members"], "height": height_of(roll_txid)[0]},
        "ballots": sorted(ballots, key=_order_key),
        "close_block_hash": close_header and header_hash(close_header),
        "administrator": administrator,
    }


def compare_input(rebuilt, given, problems):
    """What the archive says it counted must be what the txs say."""
    if not isinstance(given, dict):
        problems.append("count.json has no input.")
        return
    for part in ("election", "roll", "close_block_hash"):
        if given.get(part) != rebuilt[part]:
            problems.append(
                "count.json: its input %s isn't what the txs say: %s, not %s."
                % (part, json.dumps(given.get(part), sort_keys=True), json.dumps(rebuilt[part], sort_keys=True))
            )
    theirs = given.get("ballots") if isinstance(given.get("ballots"), list) else []
    by_txid = {b.get("txid"): b for b in theirs if isinstance(b, dict)}
    for ballot in rebuilt["ballots"]:
        if ballot["txid"] not in by_txid:
            problems.append("count.json leaves out ballot %s." % ballot["txid"])
        elif by_txid[ballot["txid"]] != ballot:
            problems.append(
                "count.json: ballot %s isn't what its tx says: %s, not %s."
                % (ballot["txid"], json.dumps(by_txid[ballot["txid"]], sort_keys=True), json.dumps(ballot, sort_keys=True))
            )
    ours = {b["txid"] for b in rebuilt["ballots"]}
    for txid in by_txid:
        if txid not in ours:
            problems.append("count.json counts ballot %s, which the archive's records don't hold." % txid)
    if [b.get("txid") for b in theirs if isinstance(b, dict)] != [b["txid"] for b in rebuilt["ballots"]] and not problems:
        problems.append("count.json lists the ballots out of chain order.")


def check_result_tx(path, app, election_id, administrator, archive_sha256, closes, close_block_hash, problems):
    """The result record, from its tx's bytes (raw, or as hex text)."""
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError:
        problems.append("%s can't be read." % path)
        return None
    text = data.strip()
    if re.fullmatch(rb"[0-9a-fA-F]+", text or b"x") and len(text) % 2 == 0:
        data = bytes.fromhex(text.decode())
    try:
        records = tx_records(data, app)
    except ValueError:
        problems.append("%s isn't a transaction." % path)
        return None
    txid = display(sha256d(data))
    results = [r for r in records if r["kind"] == "result" and r["fields"]["election"] == election_id]
    if not results:
        problems.append("tx %s (%s) holds no result record for election %s." % (txid, path, election_id))
        return None
    result = results[0]
    fields = result["fields"]
    if result["signer"] != administrator:
        problems.append(
            "tx %s: the result is signed by %s, not the election's administrator %s."
            % (txid, result["signer"], administrator)
        )
    if fields["archive_sha256"] != archive_sha256:
        problems.append(
            "tx %s: the result's archive_sha256 is %s, but MANIFEST.sha256 hashes to %s."
            % (txid, fields["archive_sha256"], archive_sha256)
        )
    if fields["closes_at_height"] != closes:
        problems.append(
            "tx %s: the result says closes_at_height %d, the election %d." % (txid, fields["closes_at_height"], closes)
        )
    if fields["close_block_hash"] != close_block_hash:
        problems.append(
            "tx %s: the result's close_block_hash is %s, but the header at height %d is %s."
            % (txid, fields["close_block_hash"], closes, close_block_hash)
        )
    return {"txid": txid, "fields": fields}



def _choices_text(choices):
    if isinstance(choices, list):
        return ", ".join(str(c) for c in choices) if choices else "(no one)"
    return json.dumps(choices)


def recount(folder, archive_sha256=None, result_tx=None):
    """Runs every step on `folder`; prints as it goes. Returns 0 when the
    recount matches, and raises Failed otherwise."""
    say("Recounting the election in %s, with no network calls." % folder)
    say()

    # 1. Files.
    files, manifest_sha256, problems = check_manifest(folder, archive_sha256)
    if not problems:
        given = "the archive_sha256 you gave" if archive_sha256 else "nothing yet (see the result tx below)"
        say("1. Files: all %d match MANIFEST.sha256, whose sha256 %s matches %s." % (len(files), manifest_sha256, given))

    index_bytes = files.get("archive.json")
    try:
        index = json.loads(index_bytes.decode("utf-8")) if index_bytes else None
    except ValueError:
        index = None
    if not isinstance(index, dict):
        problems.append("archive.json is missing or isn't JSON, so the archive can't be read.")
        raise Failed(problems)

    # 2. Headers.
    header_problems = []
    headers = check_headers(files, index, header_problems)
    problems += header_problems
    if headers and not header_problems:
        low, high = min(headers), max(headers)
        say(
            "2. Headers: %d headers, heights %d to %d; each names the one before it and meets its own target."
            % (len(headers), low, high)
        )

    # 3. Transactions and proofs.
    proof_problems = []
    placed = check_txs_and_proofs(files, index, headers, proof_problems)
    problems += proof_problems
    if not proof_problems:
        say(
            "3. Transactions: %d match their txids; %d proofs reach their block's merkle root."
            % (len(index.get("records") or []), len(placed))
        )

    if problems:
        raise Failed(problems)

    # 4. Records.
    rebuilt = read_records(files, index, placed, headers, problems)
    if problems or rebuilt is None:
        raise Failed(problems)
    say(
        "4. Records: the election and the roll are signed by %s; the roll matches roll_sha256; %d ballots read."
        % (rebuilt["administrator"], len(rebuilt["ballots"]))
    )

    try:
        count_json = json.loads(files["count.json"].decode("utf-8"))
    except (KeyError, ValueError):
        raise Failed(["count.json is missing or isn't JSON."])
    compare_input(rebuilt, count_json.get("input"), problems)
    if problems:
        raise Failed(problems)

    # 5. The count.
    try:
        result = count(
            rebuilt["election"], rebuilt["roll"], rebuilt["ballots"], rebuilt["close_block_hash"]
        )
    except Refused as refused:
        raise Failed(["The counting rule refuses this election: %s." % refused])
    say("5. The count: the rule ran on what the txs say.")

    # 6. Compare.
    published = count_json.get("result")
    if published != result:
        for key in ("ballots", "counted", "not_counted", "tally", "winners", "undecided", "election"):
            if not isinstance(published, dict) or published.get(key) != result[key]:
                problems.append(
                    "count.json: its result %s is %s, but the recount gives %s."
                    % (key, json.dumps(published.get(key) if isinstance(published, dict) else None), json.dumps(result[key]))
                )
        raise Failed(problems or ["count.json's result isn't the recount's."])

    result_record = None
    if result_tx:
        result_record = check_result_tx(
            result_tx,
            index.get("app"),
            rebuilt["election"]["election"],
            rebuilt["administrator"],
            manifest_sha256,
            rebuilt["election"]["closes_at_height"],
            rebuilt["close_block_hash"],
            problems,
        )
        if problems:
            raise Failed(problems)
    say("6. Compared: the tally and winners match count.json%s." % (" and the result record" if result_record else ""))

    # The report.
    election = rebuilt["election"]
    by_txid = {b["txid"]: b for b in rebuilt["ballots"]}
    say()
    say("Election %s" % election["election"])
    say("  %s: %d to elect, ballots count from height %d to %d."
        % (election["name"], election["number_elected"], election["opens_at_height"], election["closes_at_height"]))
    say()
    say("Ballots, in chain order:")
    for entry in result["ballots"]:
        ballot = by_txid[entry["txid"]]
        where = "height %d" % ballot["height"] if ballot["height"] is not None else "unconfirmed"
        if entry["counted"]:
            say("  counted      %s  %s  %s  for %s" % (entry["txid"], where, ballot["signer"], _choices_text(ballot["choices"])))
        else:
            reason = RULE_TEXT[entry["rule"]]
            if entry["rule"] == "replaced":
                reason = "replaced by %s" % entry["replaced_by"]
            signer = ballot["signer"] or "no signer"
            say("  not counted  %s  %s  %s  %s: %s" % (entry["txid"], where, signer, entry["rule"], reason))
    say()
    say("Tally (%d counted, %d not counted):" % (result["counted"], result["not_counted"]))
    width = max([len(t["candidate"]) for t in result["tally"]] + [1])
    for t in result["tally"]:
        say("  %s  %d" % (t["candidate"].ljust(width), t["votes"]))
    say()
    say("Winners: %s" % (", ".join(result["winners"]) or "(none)"))
    if result["undecided"]:
        say("Undecided: %d seat(s) tied between %s." % (result["undecided"]["seats"], ", ".join(result["undecided"]["tied"])))
    say()

    easy = [h for h, header in headers.items() if header_target(struct.unpack("<I", header[72:76])[0]) > MAINNET_LIMIT]
    say("To tie these headers to the real chain, look up one block on any explorer or your own node:")
    say("  block %d is %s (the close, which settles a tied seat by lot)" % (election["closes_at_height"], rebuilt["close_block_hash"]))
    top = max(headers)
    say("  block %d is %s" % (top, header_hash(headers[top])))
    if easy:
        say("  Note: %d of these headers are easier than mainnet allows, so this is a test chain." % len(easy))
    if result_record:
        say("The result record is tx %s; check that it is the one the election's page names." % result_record["txid"])
    say()
    say("Matches the published result.")
    return 0


# ---------------------------------------------------------------------------
# Self-test against the published vectors
# ---------------------------------------------------------------------------


def self_test(path):
    with open(path, "rb") as handle:
        published = json.loads(handle.read().decode("utf-8"))
    if published.get("rule_order") != RULES:
        say("The vectors' rule_order isn't this tool's: %s" % published.get("rule_order"))
        return 1
    failures = []
    vectors = published.get("vectors") or []
    for vector in vectors:
        given, expected = vector["input"], vector["expected"]
        try:
            got = count(given["election"], given["roll"], given["ballots"], given.get("close_block_hash"))
        except Refused as refused:
            if expected.get("error") != refused.kind or expected.get("error_detail") != refused.detail:
                failures.append("%s: refused (%s), expected %s" % (vector["id"], refused, json.dumps(expected)))
            continue
        except Exception as error:  # a crash is a failure too, named
            failures.append("%s: crashed: %r" % (vector["id"], error))
            continue
        if "error" in expected:
            failures.append("%s: counted, expected the refusal %s" % (vector["id"], expected["error"]))
            continue
        election = got.pop("election")
        if election != given["election"]["election"] or got != expected:
            failures.append("%s: got %s, expected %s" % (vector["id"], json.dumps(got), json.dumps(expected)))
    for failure in failures:
        say("FAIL " + failure)
    if failures:
        say("%d of %d vectors differ from this tool's count." % (len(failures), len(vectors)))
        return 1
    say("All %d vectors in %s match this tool's count." % (len(vectors), os.path.basename(path)))
    return 0


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="recount.py",
        description="Recount a Bitblocks election from its archive alone, offline.",
        epilog="Guide: https://bitblocks.app/elections/recount.html",
    )
    parser.add_argument("folder", nargs="?", help="the archive folder (holding MANIFEST.sha256)")
    parser.add_argument("--archive-sha256", help="the archive_sha256 the result record carries")
    parser.add_argument("--result-tx", help="the result record's tx, as a raw or hex file")
    parser.add_argument("--self-test", metavar="VECTORS", help="run the rule's published vectors instead")
    parser.add_argument("--version", action="version", version="recount.py " + VERSION)
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test(args.self_test)

    if not args.folder:
        parser.print_usage()
        say("Give the archive folder, and the archive_sha256 from the result record.")
        return 2
    if not os.path.isdir(args.folder):
        say("%s isn't a folder. Unzip the archive first, and give its folder." % args.folder)
        return 2
    archive_sha256 = args.archive_sha256 and args.archive_sha256.strip().lower()
    if archive_sha256 and not HEX64.fullmatch(archive_sha256):
        say("--archive-sha256 must be 64 hex characters, as the result record carries it.")
        return 2
    if not archive_sha256 and not args.result_tx:
        say(
            "Give --archive-sha256 (from the result record, on the election's page) or --result-tx, "
            "so the recount can tell this is the archive the result was published for."
        )
        return 2

    try:
        return recount(args.folder, archive_sha256, args.result_tx)
    except Failed as failed:
        say()
        say("Does not match. The archive failed these checks:")
        for problem in failed.problems:
            say("  - " + problem)
        say()
        say("No tally is printed, because the archive didn't check out.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
