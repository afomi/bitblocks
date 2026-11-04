import { test, describe } from "node:test"
import assert from "node:assert/strict"
import * as tiles from "./tiles.mjs"

const {
  TILE_RECORDS,
  FAN_OUT,
  MAX_LEVEL,
  HEADER_BYTES,
  STATE_NAMES,
  COMPLETED,
  decodeTile,
  isGap,
  gapFraction,
  log10Scale,
  binOf,
  spanOf,
  tileSpan,
  tileIndex,
  recordIndex,
  tileRange,
  levelFor,
  tilesFor,
  tileUrl,
  tileKey,
  step,
  parseHeight,
  keyDelta,
  meanTx,
  stateName
} = tiles

function writeHeader(view, { level, recordSize, firstHeight, count, span, builtAt }) {
  const magic = "BBT1"
  for (let i = 0; i < 4; i++) view.setUint8(i, magic.charCodeAt(i))
  view.setUint8(4, 1)
  view.setUint8(5, level)
  view.setUint16(6, recordSize, true)
  view.setUint32(8, firstHeight, true)
  view.setUint32(12, count, true)
  view.setUint32(16, span, true)
  view.setUint32(20, builtAt, true)
  // 24..31 reserved zeros (ArrayBuffer is zero-initialised)
}

function buildLeafTile(records, { firstHeight = 0, builtAt = 1762000000 } = {}) {
  const buf = new ArrayBuffer(HEADER_BYTES + records.length * 16)
  const view = new DataView(buf)
  writeHeader(view, { level: 0, recordSize: 16, firstHeight, count: records.length, span: 1, builtAt })
  records.forEach((r, i) => {
    const o = HEADER_BYTES + i * 16
    view.setUint32(o, r.time, true)
    view.setFloat32(o + 4, r.size, true)
    view.setUint32(o + 8, r.numTx, true)
    view.setUint8(o + 12, r.state)
  })
  return buf
}

function buildRollupTile(level, records, { firstHeight = 0, builtAt = 1762000000 } = {}) {
  const buf = new ArrayBuffer(HEADER_BYTES + records.length * 64)
  const view = new DataView(buf)
  writeHeader(view, {
    level,
    recordSize: 64,
    firstHeight,
    count: records.length,
    span: FAN_OUT ** level,
    builtAt
  })
  records.forEach((r, i) => {
    const o = HEADER_BYTES + i * 64
    view.setUint32(o, r.present, true)
    view.setUint32(o + 4, r.completed, true)
    view.setUint32(o + 8, r.timeMin, true)
    view.setUint32(o + 12, r.timeMax, true)
    view.setFloat64(o + 16, r.sizeSum, true)
    view.setFloat64(o + 24, r.txSum, true)
    view.setFloat32(o + 32, r.sizeMax, true)
    view.setUint32(o + 36, r.txMax, true)
    r.hist.forEach((h, b) => view.setUint16(o + 40 + b * 2, h, true))
  })
  return buf
}

describe("constants", () => {
  test("tile geometry constants", () => {
    assert.equal(TILE_RECORDS, 1024)
    assert.equal(FAN_OUT, 32)
    assert.equal(MAX_LEVEL, 3)
    assert.equal(HEADER_BYTES, 32)
    assert.equal(COMPLETED, 6)
  })

  test("state names index by state code", () => {
    assert.equal(STATE_NAMES.length, 8)
    assert.equal(STATE_NAMES[0], "missing")
    assert.equal(STATE_NAMES[6], "completed")
    assert.equal(STATE_NAMES[7], "failed")
    assert.equal(stateName(6), "completed")
    assert.equal(stateName(42), "unknown(42)")
  })
})

describe("decodeTile level 0", () => {
  const recs = [
    { time: 1231006505, size: 285, numTx: 1, state: 6 },
    { time: 0, size: 0, numTx: 0, state: 0 },
    { time: 1231469744, size: 215.5, numTx: 2, state: 2 }
  ]

  test("round-trips header and records", () => {
    const buf = buildLeafTile(recs, { firstHeight: 2048, builtAt: 1762000000 })
    const t = decodeTile(buf)
    assert.equal(t.level, 0)
    assert.equal(t.recordSize, 16)
    assert.equal(t.firstHeight, 2048)
    assert.equal(t.count, 3)
    assert.equal(t.span, 1)
    assert.equal(t.builtAt, 1762000000)
    assert.equal(t.records.length, 3)

    assert.deepEqual(t.records[0], { height: 2048, time: 1231006505, size: 285, numTx: 1, state: 6 })
    assert.deepEqual(t.records[1], { height: 2049, time: 0, size: 0, numTx: 0, state: 0 })
    assert.equal(t.records[2].height, 2050)
    assert.equal(t.records[2].numTx, 2)
    assert.equal(t.records[2].state, 2)
    assert.ok(Math.abs(t.records[2].size - 215.5) < 1e-3)
  })

  test("accepts a Uint8Array view", () => {
    const buf = buildLeafTile(recs)
    const padded = new Uint8Array(buf.byteLength + 8)
    padded.set(new Uint8Array(buf), 4)
    const t = decodeTile(padded.subarray(4, 4 + buf.byteLength))
    assert.equal(t.count, 3)
    assert.equal(t.records[0].numTx, 1)
  })

  test("partial last tile keeps count < TILE_RECORDS", () => {
    const partial = Array.from({ length: 5 }, (_, i) => ({ time: 100 + i, size: 1000 * i, numTx: i, state: 6 }))
    const t = decodeTile(buildLeafTile(partial, { firstHeight: 1024 * 947 }))
    assert.equal(t.count, 5)
    assert.ok(t.count < TILE_RECORDS)
    assert.equal(t.records.at(-1).height, 1024 * 947 + 4)
  })

  test("a full tile of 1024 records decodes", () => {
    const full = Array.from({ length: TILE_RECORDS }, (_, i) => ({ time: i, size: i, numTx: i, state: i % 8 }))
    const t = decodeTile(buildLeafTile(full))
    assert.equal(t.count, TILE_RECORDS)
    assert.equal(t.records[1023].numTx, 1023)
    assert.equal(t.records[1023].state, 7)
  })

  test("gaps are any state other than completed", () => {
    const t = decodeTile(buildLeafTile(recs))
    assert.equal(isGap(t.records[0].state), false)
    assert.equal(isGap(t.records[1].state), true)
    assert.equal(isGap(t.records[2].state), true)
  })
})

describe("decodeTile level >= 1", () => {
  const recs = [
    {
      present: 32,
      completed: 32,
      timeMin: 1231006505,
      timeMax: 1231470000,
      sizeSum: 32 * 215,
      txSum: 40,
      sizeMax: 285,
      txMax: 3,
      hist: [30, 2, 0, 0, 0, 0, 0, 0]
    },
    {
      present: 20,
      completed: 4,
      timeMin: 1600000000,
      timeMax: 1600100000,
      sizeSum: 4.5e9,
      txSum: 3_500_000,
      sizeMax: 2.3e9,
      txMax: 2_800_000,
      hist: [1, 2, 3, 4, 5, 3, 2, 0]
    }
  ]

  test("round-trips level 1 records", () => {
    const buf = buildRollupTile(1, recs, { firstHeight: 32 * 1024 * 3 })
    const t = decodeTile(buf)
    assert.equal(t.level, 1)
    assert.equal(t.recordSize, 64)
    assert.equal(t.span, 32)
    assert.equal(t.count, 2)
    assert.equal(t.firstHeight, 32 * 1024 * 3)

    const a = t.records[0]
    assert.equal(a.height, 32 * 1024 * 3)
    assert.equal(a.present, 32)
    assert.equal(a.completed, 32)
    assert.equal(a.timeMin, 1231006505)
    assert.equal(a.timeMax, 1231470000)
    assert.equal(a.sizeSum, 32 * 215)
    assert.equal(a.txSum, 40)
    assert.equal(a.sizeMax, 285)
    assert.equal(a.txMax, 3)
    assert.deepEqual(a.hist, [30, 2, 0, 0, 0, 0, 0, 0])

    const b = t.records[1]
    assert.equal(b.height, 32 * 1024 * 3 + 32)
    assert.equal(b.present, 20)
    assert.equal(b.completed, 4)
    assert.equal(b.txSum, 3_500_000)
    assert.equal(b.txMax, 2_800_000)
    assert.ok(Math.abs(b.sizeMax - 2.3e9) / 2.3e9 < 1e-6)
    assert.deepEqual(b.hist, [1, 2, 3, 4, 5, 3, 2, 0])
  })

  test("decodes level 2 and level 3 spans", () => {
    const t2 = decodeTile(buildRollupTile(2, recs))
    assert.equal(t2.span, 1024)
    assert.equal(t2.records[1].height, 1024)
    const t3 = decodeTile(buildRollupTile(3, recs))
    assert.equal(t3.span, 32768)
    assert.equal(t3.records[1].height, 32768)
  })

  test("gapFraction and meanTx", () => {
    const t = decodeTile(buildRollupTile(1, recs))
    assert.equal(gapFraction(t.records[0], 32), 0)
    assert.equal(gapFraction(t.records[1], 32), (32 - 4) / 32)
    assert.equal(gapFraction({ completed: 0 }, 32), 1)
    assert.equal(gapFraction({ completed: 40 }, 32), 0, "clamps to 0 when over-complete")
    assert.equal(gapFraction({}, 0), 0)
    assert.equal(meanTx(t.records[1]), 3_500_000 / 20)
    assert.equal(meanTx({ present: 0, txSum: 0 }), 0)
  })
})

describe("decodeTile errors", () => {
  test("throws on bad magic", () => {
    const buf = buildLeafTile([{ time: 1, size: 1, numTx: 1, state: 6 }])
    new DataView(buf).setUint8(0, "X".charCodeAt(0))
    assert.throws(() => decodeTile(buf), /bad magic/)
  })

  test("throws on unsupported version", () => {
    const buf = buildLeafTile([{ time: 1, size: 1, numTx: 1, state: 6 }])
    new DataView(buf).setUint8(4, 2)
    assert.throws(() => decodeTile(buf), /version 2/)
  })

  test("throws on short header", () => {
    assert.throws(() => decodeTile(new ArrayBuffer(10)), /short header/)
  })

  test("throws when record_size disagrees with level", () => {
    const buf = buildLeafTile([{ time: 1, size: 1, numTx: 1, state: 6 }])
    new DataView(buf).setUint16(6, 64, true)
    assert.throws(() => decodeTile(buf), /record_size/)
  })

  test("throws when span disagrees with level", () => {
    const buf = buildRollupTile(1, [])
    new DataView(buf).setUint32(16, 1024, true)
    assert.throws(() => decodeTile(buf), /span/)
  })

  test("throws when the buffer is shorter than count says", () => {
    const buf = buildLeafTile([{ time: 1, size: 1, numTx: 1, state: 6 }])
    new DataView(buf).setUint32(12, 50, true)
    assert.throws(() => decodeTile(buf), /records need/)
  })

  test("throws on non-buffer input", () => {
    assert.throws(() => decodeTile("nope"), TypeError)
  })

  test("zero-record tile decodes to an empty records array", () => {
    const t = decodeTile(buildLeafTile([]))
    assert.equal(t.count, 0)
    assert.deepEqual(t.records, [])
  })
})

describe("scales and bins", () => {
  test("log10Scale", () => {
    assert.equal(log10Scale(0), 0)
    assert.equal(log10Scale(9), 1)
    assert.equal(log10Scale(999), 3)
    assert.ok(Math.abs(log10Scale(2_800_000) - Math.log10(2_800_001)) < 1e-12)
    assert.equal(log10Scale(-5), 0)
    assert.equal(log10Scale(NaN), 0)
  })

  test("binOf matches clamp(floor(log10(num_tx)), 0, 7)", () => {
    assert.equal(binOf(0), -1)
    assert.equal(binOf(1), 0)
    assert.equal(binOf(9), 0)
    assert.equal(binOf(10), 1)
    assert.equal(binOf(99), 1)
    assert.equal(binOf(100), 2)
    assert.equal(binOf(2_800_000), 6)
    assert.equal(binOf(10_000_000), 7)
    assert.equal(binOf(1e12), 7, "clamps at bin 7")
    assert.equal(binOf(-3), -1)
  })
})

describe("height arithmetic", () => {
  test("spanOf and tileSpan", () => {
    assert.equal(spanOf(0), 1)
    assert.equal(spanOf(1), 32)
    assert.equal(spanOf(2), 1024)
    assert.equal(spanOf(3), 32768)
    assert.equal(tileSpan(0), 1024)
    assert.equal(tileSpan(1), 32768)
    assert.equal(tileSpan(3), 1024 * 32768)
  })

  test("tileIndex", () => {
    assert.equal(tileIndex(0, 0), 0)
    assert.equal(tileIndex(1023, 0), 0)
    assert.equal(tileIndex(1024, 0), 1)
    assert.equal(tileIndex(971234, 0), 948)
    assert.equal(tileIndex(971234, 1), 29)
    assert.equal(tileIndex(971234, 2), 0)
    assert.equal(tileIndex(971234, 3), 0)
  })

  test("recordIndex is the index within the tile", () => {
    assert.equal(recordIndex(0, 0), 0)
    assert.equal(recordIndex(1023, 0), 1023)
    assert.equal(recordIndex(1024, 0), 0)
    assert.equal(recordIndex(971234, 0), 971234 - 948 * 1024)
    assert.equal(recordIndex(31, 1), 0)
    assert.equal(recordIndex(32, 1), 1)
    assert.equal(recordIndex(971234, 1), Math.floor((971234 - 29 * 32768) / 32))
    assert.equal(recordIndex(971234, 2), Math.floor(971234 / 1024))
    assert.equal(recordIndex(971234, 3), 29)
  })

  test("tileRange", () => {
    assert.deepEqual(tileRange(0, 0), [0, 1024])
    assert.deepEqual(tileRange(0, 948), [948 * 1024, 949 * 1024])
    assert.deepEqual(tileRange(1, 2), [65536, 98304])
    assert.deepEqual(tileRange(3, 0), [0, 33554432])
  })

  test("tileIndex/recordIndex invert tileRange", () => {
    for (const level of [0, 1, 2, 3]) {
      for (const h of [0, 1, 31, 32, 1023, 1024, 500_000, 971234]) {
        const idx = tileIndex(h, level)
        const [lo, hi] = tileRange(level, idx)
        assert.ok(h >= lo && h < hi, `h=${h} level=${level}`)
        const r = recordIndex(h, level)
        assert.ok(r >= 0 && r < TILE_RECORDS)
        assert.equal(lo + r * spanOf(level) <= h, true)
        assert.equal(h < lo + (r + 1) * spanOf(level), true)
      }
    }
  })
})

describe("levelFor", () => {
  test("picks the smallest level that fits the record budget", () => {
    assert.equal(levelFor(100), 0)
    assert.equal(levelFor(4096), 0)
    assert.equal(levelFor(4097), 1)
    assert.equal(levelFor(4096 * 32), 1)
    assert.equal(levelFor(4096 * 32 + 1), 2)
    assert.equal(levelFor(1_000_000), 2)
    assert.equal(levelFor(4096 * 1024), 2)
    assert.equal(levelFor(4096 * 1024 + 1), 3)
  })

  test("never exceeds MAX_LEVEL", () => {
    assert.equal(levelFor(1e12), MAX_LEVEL)
  })

  test("honours a custom budget", () => {
    assert.equal(levelFor(1_000_000, 1_000_000), 0)
    assert.equal(levelFor(1_000_000, 1000), 2)
    assert.equal(levelFor(1_000_000, 900), 3)
    assert.equal(levelFor(1_000_000, 40_000), 1)
  })

  test("tolerates zero or negative viewport", () => {
    assert.equal(levelFor(0), 0)
    assert.equal(levelFor(-10), 0)
  })
})

describe("tilesFor", () => {
  test("covers an inclusive range", () => {
    assert.deepEqual(tilesFor(0, 1023, 0), [0])
    assert.deepEqual(tilesFor(0, 1024, 0), [0, 1])
    assert.deepEqual(tilesFor(5000, 5000, 0), [4])
    assert.deepEqual(tilesFor(0, 971234, 1), Array.from({ length: 30 }, (_, i) => i))
    assert.deepEqual(tilesFor(0, 971234, 2), [0])
    assert.deepEqual(tilesFor(0, 971234, 3), [0])
  })

  test("swaps reversed bounds and clamps negatives", () => {
    assert.deepEqual(tilesFor(1024, 0, 0), [0, 1])
    assert.deepEqual(tilesFor(-50, 10, 0), [0])
  })

  test("level 0 over the whole chain is many tiles", () => {
    assert.equal(tilesFor(0, 971234, 0).length, 949)
  })
})

describe("tileUrl", () => {
  const manifest = {
    version: 1,
    tip_height: 971234,
    tile_records: 1024,
    fan_out: 32,
    levels: [
      { level: 0, span: 1, tiles: ["a1b2c3d4e5f60718", null, "ffffffffffffffff"] },
      { level: 1, span: 32, tiles: ["0123456789abcdef"] }
    ]
  }

  test("builds a versioned url", () => {
    assert.equal(tileUrl("/chain-scrubber/tiles", manifest, 0, 0), "/chain-scrubber/tiles/0/0?v=a1b2c3d4e5f60718")
    assert.equal(tileUrl("/chain-scrubber/tiles/", manifest, 0, 2), "/chain-scrubber/tiles/0/2?v=ffffffffffffffff")
    assert.equal(tileUrl("/chain-scrubber/tiles", manifest, 1, 0), "/chain-scrubber/tiles/1/0?v=0123456789abcdef")
  })

  test("returns null for absent tiles", () => {
    assert.equal(tileUrl("/t", manifest, 0, 1), null)
    assert.equal(tileUrl("/t", manifest, 0, 99), null)
    assert.equal(tileUrl("/t", manifest, 2, 0), null)
    assert.equal(tileUrl("/t", null, 0, 0), null)
    assert.equal(tileUrl("/t", {}, 0, 0), null)
  })

  test("tileKey", () => {
    assert.equal(tileKey(0, 948), "0/948")
  })
})

describe("step", () => {
  test("clamps to [0, tip]", () => {
    assert.equal(step(0, -1, 100), 0)
    assert.equal(step(0, 1, 100), 1)
    assert.equal(step(100, 1, 100), 100)
    assert.equal(step(50, 1024, 100), 100)
    assert.equal(step(50, -1024, 100), 0)
    assert.equal(step(50, 0, 100), 50)
  })

  test("rounds and tolerates garbage", () => {
    assert.equal(step(10.4, 0, 100), 10)
    assert.equal(step(NaN, 5, 100), 5)
    assert.equal(step(5, NaN, 100), 5)
    assert.equal(step(5, 5, NaN), 0)
  })
})

describe("parseHeight", () => {
  test("accepts plain digits", () => {
    assert.equal(parseHeight("0", 100), 0)
    assert.equal(parseHeight("42", 100), 42)
    assert.equal(parseHeight("100", 100), 100)
  })

  test("trims and accepts separators", () => {
    assert.equal(parseHeight("  971,234 ", 1_000_000), 971234)
    assert.equal(parseHeight("971_234", 1_000_000), 971234)
    assert.equal(parseHeight("971 234", 1_000_000), 971234)
  })

  test("rejects negatives, non-numbers, above tip, empty", () => {
    assert.equal(parseHeight("-1", 100), null)
    assert.equal(parseHeight("abc", 100), null)
    assert.equal(parseHeight("12abc", 100), null)
    assert.equal(parseHeight("1.5", 100), null)
    assert.equal(parseHeight("101", 100), null)
    assert.equal(parseHeight("", 100), null)
    assert.equal(parseHeight("   ", 100), null)
    assert.equal(parseHeight(null, 100), null)
    assert.equal(parseHeight(undefined, 100), null)
    assert.equal(parseHeight("1e3", 100), null)
  })

  test("accepts numbers as input", () => {
    assert.equal(parseHeight(7, 100), 7)
  })
})

describe("keyDelta", () => {
  test("arrows", () => {
    assert.equal(keyDelta("ArrowRight", false), 1)
    assert.equal(keyDelta("ArrowLeft", false), -1)
    assert.equal(keyDelta("ArrowRight", true), 32)
    assert.equal(keyDelta("ArrowLeft", true), -32)
  })

  test("pages", () => {
    assert.equal(keyDelta("PageUp", false), 1024)
    assert.equal(keyDelta("PageDown", false), -1024)
  })

  test("home and end", () => {
    assert.equal(keyDelta("Home"), "home")
    assert.equal(keyDelta("End"), "end")
  })

  test("anything else is null", () => {
    assert.equal(keyDelta("a"), null)
    assert.equal(keyDelta("Enter"), null)
    assert.equal(keyDelta(" "), null)
    assert.equal(keyDelta(undefined), null)
  })
})

describe("columnFor", () => {
  const { columnFor } = tiles

  test("an unloaded record is a placeholder, not data", () => {
    assert.deepEqual(columnFor(null, 0), { kind: "unloaded", tx: 0, size: 0, gap: 1, mean: 0 })
  })

  test("a missing leaf has no height", () => {
    const c = columnFor({ state: 0, numTx: 0, size: 0 }, 0)
    assert.equal(c.kind, "missing")
    assert.equal(c.tx, 0)
  })

  test("a completed leaf draws its tx count", () => {
    const c = columnFor({ state: COMPLETED, numTx: 12, size: 4000 }, 0)
    assert.deepEqual(c, { kind: "completed", tx: 12, size: 4000, gap: 0, mean: 0 })
  })

  test("a gap leaf keeps its header tx count, so zooming in does not flatten it", () => {
    const leaf = columnFor({ state: 2, numTx: 120, size: 0 }, 0)
    assert.equal(leaf.kind, "gap")
    assert.equal(leaf.tx, 120)
    assert.equal(leaf.gap, 1)

    // The same block rolled up alone into a bucket draws at the same height.
    const bucket = columnFor({ present: 1, completed: 0, txMax: 120, sizeMax: 0, txSum: 120 }, 1)
    assert.equal(bucket.tx, leaf.tx)
    assert.equal(bucket.gap, 1)
  })

  test("a rollup draws its largest block and its gap share", () => {
    const c = columnFor({ present: 32, completed: 8, txMax: 900, sizeMax: 2e5, txSum: 3200 }, 1)
    assert.equal(c.kind, "rollup")
    assert.equal(c.tx, 900)
    assert.equal(c.size, 2e5)
    assert.equal(c.gap, 24 / 32)
    assert.equal(c.mean, 100)
  })

  test("heights above the tip are not gaps", () => {
    // The tip bucket of level 1 holds 20 blocks, all completed.
    const c = columnFor({ present: 20, completed: 20, txMax: 5, sizeMax: 1, txSum: 40 }, 1, 20)
    assert.equal(c.gap, 0)
    assert.equal(columnFor({ present: 20, completed: 10, txMax: 5, sizeMax: 1, txSum: 40 }, 1, 20).gap, 0.5)
  })

  test("an empty rollup is missing", () => {
    assert.equal(columnFor({ present: 0, completed: 0, txMax: 0, sizeMax: 0, txSum: 0 }, 2).kind, "missing")
  })
})

describe("axisDecades", () => {
  const { axisDecades } = tiles

  test("the early chain gets a short axis so its columns are not flattened", () => {
    assert.equal(axisDecades(2_000), 4)
  })

  test("never below three decades", () => {
    assert.equal(axisDecades(0), 3)
    assert.equal(axisDecades(9), 3)
  })

  test("the whole chain keeps the full axis", () => {
    assert.equal(axisDecades(3_900_000), 7)
    assert.equal(axisDecades(1e12), 7.5)
  })

  test("garbage falls back to the full axis", () => {
    assert.equal(axisDecades(NaN), 7.5)
    assert.equal(axisDecades(undefined), 7.5)
  })
})

describe("tileTxMax", () => {
  const { tileTxMax } = tiles

  test("reads the largest block from a rollup tile", () => {
    const t = decodeTile(
      buildRollupTile(2, [
        { present: 10, completed: 0, timeMin: 1, timeMax: 2, sizeSum: 0, txSum: 20, sizeMax: 0, txMax: 7, hist: [0, 0, 0, 0, 0, 0, 0, 0] },
        { present: 10, completed: 0, timeMin: 1, timeMax: 2, sizeSum: 0, txSum: 20, sizeMax: 0, txMax: 2100, hist: [0, 0, 0, 0, 0, 0, 0, 0] }
      ])
    )
    assert.equal(tileTxMax(t), 2100)
  })

  test("reads the largest block from a leaf tile", () => {
    const t = decodeTile(buildLeafTile([{ time: 1, size: 0, numTx: 3, state: 2 }, { time: 2, size: 0, numTx: 1, state: 6 }]))
    assert.equal(tileTxMax(t), 3)
  })

  test("only counts records that overlap [h0, h1]", () => {
    const rec = (txMax) => ({ present: 1, completed: 0, timeMin: 1, timeMax: 2, sizeSum: 0, txSum: txMax, sizeMax: 0, txMax, hist: [0, 0, 0, 0, 0, 0, 0, 0] })
    // Level 1: records cover 32 heights each, so [0, 31], [32, 63], [64, 95].
    const t = decodeTile(buildRollupTile(1, [rec(5), rec(40), rec(9_000_000)]))
    assert.equal(tileTxMax(t, 0, 63), 40)
    assert.equal(tileTxMax(t, 40, 64), 9_000_000)
    assert.equal(tileTxMax(t, 0, 10), 5)
    assert.equal(tileTxMax(t, 200, 300), 0)
  })

  test("no tile, no maximum", () => {
    assert.equal(tileTxMax(null), null)
  })
})

describe("clampView", () => {
  const { clampView } = tiles

  test("whole-number bounds even for fractional input", () => {
    assert.deepEqual(clampView(10.4, 99.7, 200_000, 16), { h0: 10, h1: 100 })
  })

  test("keeps the minimum span and stays inside [0, tip]", () => {
    assert.deepEqual(clampView(5, 6, 200_000, 16), { h0: 5, h1: 20 })
    assert.deepEqual(clampView(-50, 10, 200_000, 16), { h0: 0, h1: 60 })
    assert.deepEqual(clampView(199_990, 200_050, 200_000, 16), { h0: 199_940, h1: 200_000 })
  })

  test("never wider than the chain", () => {
    assert.deepEqual(clampView(0, 1e9, 200_000, 16), { h0: 0, h1: 200_000 })
  })
})

describe("changedTiles", () => {
  const m = (levels) => ({ version: 1, levels: levels.map(([level, tiles]) => ({ level, tiles })) })

  test("names the tiles whose hash moved, and new tiles, across levels", () => {
    const before = m([[0, ["a", "b", "c"]], [1, ["x"]]])
    const after = m([[0, ["a", "B", "c", "d"]], [1, ["X"]]])
    assert.deepEqual(tiles.changedTiles(before, after).sort(), ["0/1", "0/3", "1/0"])
  })

  test("nothing changed, nothing to refetch", () => {
    const same = m([[0, ["a"]]])
    assert.deepEqual(tiles.changedTiles(same, same), [])
  })

  test("no earlier manifest: nothing to compare", () => {
    assert.deepEqual(tiles.changedTiles(null, m([[0, ["a"]]])), [])
  })
})
