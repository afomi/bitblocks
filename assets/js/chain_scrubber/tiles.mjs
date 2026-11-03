// Pure logic for the chain scrubber: binary tile decoding, level selection,
// height arithmetic and input parsing.
// No DOM, no three.js — everything here runs under `node --test`.

export const TILE_RECORDS = 1024
export const FAN_OUT = 32
export const MAX_LEVEL = 3
export const HEADER_BYTES = 32
export const LEAF_RECORD_SIZE = 16
export const ROLLUP_RECORD_SIZE = 64
export const MAGIC = "BBT1"
export const VERSION = 1
export const COMPLETED = 6
export const HIST_BINS = 8

export const STATE_NAMES = [
  "missing",
  "pending",
  "header_only",
  "header_synced",
  "txs_queued",
  "txs_syncing",
  "completed",
  "failed"
]

export function stateName(state) {
  return STATE_NAMES[state] || `unknown(${state})`
}

export function isGap(state) {
  return state !== COMPLETED
}

export function gapFraction(record, span) {
  if (!span || span <= 0) return 0
  const completed = record && Number.isFinite(record.completed) ? record.completed : 0
  const f = (span - completed) / span
  return Math.min(1, Math.max(0, f))
}

export function log10Scale(n) {
  if (!Number.isFinite(n) || n < 0) return 0
  return Math.log10(n + 1)
}

export function binOf(numTx) {
  if (!Number.isFinite(numTx) || numTx < 1) return -1
  const b = Math.floor(Math.log10(numTx))
  return Math.min(HIST_BINS - 1, Math.max(0, b))
}

export function spanOf(level) {
  return FAN_OUT ** level
}

// Blocks covered by one tile at this level.
export function tileSpan(level) {
  return TILE_RECORDS * spanOf(level)
}

export function tileIndex(height, level) {
  return Math.floor(height / tileSpan(level))
}

// Index of the record within its tile.
export function recordIndex(height, level) {
  return Math.floor((height % tileSpan(level)) / spanOf(level))
}

// [firstHeight, lastHeightExclusive]
export function tileRange(level, idx) {
  const s = tileSpan(level)
  return [idx * s, (idx + 1) * s]
}

// Smallest level whose record count for `visibleBlocks` fits the budget.
export function levelFor(visibleBlocks, maxRecords = 4096) {
  const blocks = Math.max(1, visibleBlocks)
  for (let level = 0; level <= MAX_LEVEL; level++) {
    if (blocks / spanOf(level) <= maxRecords) return level
  }
  return MAX_LEVEL
}

// Tile indices covering the inclusive height range [h0, h1].
export function tilesFor(h0, h1, level) {
  const lo = Math.max(0, Math.min(h0, h1))
  const hi = Math.max(0, Math.max(h0, h1))
  const first = tileIndex(lo, level)
  const last = tileIndex(hi, level)
  const out = []
  for (let i = first; i <= last; i++) out.push(i)
  return out
}

export function tileHash(manifest, level, idx) {
  if (!manifest || !Array.isArray(manifest.levels)) return null
  const lv = manifest.levels.find((l) => l && l.level === level)
  if (!lv || !Array.isArray(lv.tiles)) return null
  const hash = lv.tiles[idx]
  return typeof hash === "string" && hash.length > 0 ? hash : null
}

export function tileUrl(base, manifest, level, idx) {
  const hash = tileHash(manifest, level, idx)
  if (!hash) return null
  const b = String(base || "").replace(/\/+$/, "")
  return `${b}/${level}/${idx}?v=${encodeURIComponent(hash)}`
}

export function tileKey(level, idx) {
  return `${level}/${idx}`
}

export function step(height, delta, tip) {
  const t = Math.max(0, Math.floor(Number.isFinite(tip) ? tip : 0))
  const h = (Number.isFinite(height) ? height : 0) + (Number.isFinite(delta) ? delta : 0)
  return Math.min(t, Math.max(0, Math.round(h)))
}

export function parseHeight(text, tip) {
  if (text === null || text === undefined) return null
  const cleaned = String(text).trim().replace(/[,_\s]/g, "")
  if (cleaned === "" || !/^\d+$/.test(cleaned)) return null
  const n = Number(cleaned)
  if (!Number.isSafeInteger(n) || n < 0) return null
  if (Number.isFinite(tip) && n > tip) return null
  return n
}

export function keyDelta(key, shiftKey = false) {
  switch (key) {
    case "ArrowRight":
    case "ArrowUp":
      return shiftKey ? FAN_OUT : 1
    case "ArrowLeft":
    case "ArrowDown":
      return shiftKey ? -FAN_OUT : -1
    case "PageUp":
      return TILE_RECORDS
    case "PageDown":
      return -TILE_RECORDS
    case "Home":
      return "home"
    case "End":
      return "end"
    default:
      return null
  }
}

function readMagic(view) {
  let s = ""
  for (let i = 0; i < 4; i++) s += String.fromCharCode(view.getUint8(i))
  return s
}

export function decodeTile(arrayBuffer) {
  const buf = arrayBuffer instanceof ArrayBuffer
    ? arrayBuffer
    : ArrayBuffer.isView(arrayBuffer)
      ? arrayBuffer.buffer.slice(arrayBuffer.byteOffset, arrayBuffer.byteOffset + arrayBuffer.byteLength)
      : null
  if (!buf) throw new TypeError("decodeTile: expected an ArrayBuffer")
  if (buf.byteLength < HEADER_BYTES) throw new Error(`decodeTile: short header (${buf.byteLength} bytes)`)

  const view = new DataView(buf)
  const magic = readMagic(view)
  if (magic !== MAGIC) throw new Error(`decodeTile: bad magic ${JSON.stringify(magic)}`)
  const version = view.getUint8(4)
  if (version !== VERSION) throw new Error(`decodeTile: unsupported version ${version}`)

  const level = view.getUint8(5)
  const recordSize = view.getUint16(6, true)
  const firstHeight = view.getUint32(8, true)
  const count = view.getUint32(12, true)
  const span = view.getUint32(16, true)
  const builtAt = view.getUint32(20, true)

  const expectedSize = level === 0 ? LEAF_RECORD_SIZE : ROLLUP_RECORD_SIZE
  if (recordSize !== expectedSize) {
    throw new Error(`decodeTile: level ${level} record_size ${recordSize}, expected ${expectedSize}`)
  }
  if (span !== spanOf(level)) {
    throw new Error(`decodeTile: level ${level} span ${span}, expected ${spanOf(level)}`)
  }
  const needed = HEADER_BYTES + count * recordSize
  if (buf.byteLength < needed) {
    throw new Error(`decodeTile: ${count} records need ${needed} bytes, have ${buf.byteLength}`)
  }

  const records = new Array(count)
  if (level === 0) {
    for (let i = 0; i < count; i++) {
      const o = HEADER_BYTES + i * recordSize
      records[i] = {
        height: firstHeight + i,
        time: view.getUint32(o, true),
        size: view.getFloat32(o + 4, true),
        numTx: view.getUint32(o + 8, true),
        state: view.getUint8(o + 12)
      }
    }
  } else {
    for (let i = 0; i < count; i++) {
      const o = HEADER_BYTES + i * recordSize
      const hist = new Array(HIST_BINS)
      for (let b = 0; b < HIST_BINS; b++) hist[b] = view.getUint16(o + 40 + b * 2, true)
      records[i] = {
        height: firstHeight + i * span,
        present: view.getUint32(o, true),
        completed: view.getUint32(o + 4, true),
        timeMin: view.getUint32(o + 8, true),
        timeMax: view.getUint32(o + 12, true),
        sizeSum: view.getFloat64(o + 16, true),
        txSum: view.getFloat64(o + 24, true),
        sizeMax: view.getFloat32(o + 32, true),
        txMax: view.getUint32(o + 36, true),
        hist
      }
    }
  }

  return { level, recordSize, firstHeight, count, span, builtAt, records }
}

// Mean tx per present block in a rollup record (0 when nothing is present).
export function meanTx(record) {
  if (!record || !record.present) return 0
  return record.txSum / record.present
}

// What one column draws, the same way at every level, so zooming in or out
// never changes a block's height: a leaf is its own bucket of one.
// `tx` and `size` are the largest block in the column (header values count:
// a block that is not completed still has a tx count from its header);
// `gap` is the share of the column's blocks that are not completed, which
// the scene draws as red; pass `blocksInBucket` for the bucket at the tip. Missing rows and unloaded tiles have no height.
export function columnFor(record, level, blocksInBucket) {
  if (!record) return { kind: "unloaded", tx: 0, size: 0, gap: 1, mean: 0 }
  if (level === 0) {
    if (record.state === 0) return { kind: "missing", tx: 0, size: 0, gap: 1, mean: 0 }
    const gap = isGap(record.state) ? 1 : 0
    return { kind: gap ? "gap" : "completed", tx: record.numTx || 0, size: record.size || 0, gap, mean: 0 }
  }
  if (!record.present) return { kind: "missing", tx: 0, size: 0, gap: 1, mean: 0 }
  return {
    kind: "rollup",
    tx: record.txMax || 0,
    size: record.sizeMax || 0,
    gap: gapFraction(record, bucketBlocks(level, blocksInBucket)),
    mean: meanTx(record)
  }
}

// Blocks that exist in a bucket: the span, or fewer in the bucket holding the
// tip, so heights above the tip never count as gaps.
function bucketBlocks(level, blocksInBucket) {
  const span = spanOf(level)
  return Number.isFinite(blocksInBucket) && blocksInBucket > 0 ? Math.min(span, blocksInBucket) : span
}

export const MIN_DECADES = 3
export const MAX_DECADES = 7.5

// How many powers of ten the column axis spans, from the chain's largest block.
// Fixed for the whole chain (not the viewport), so columns stay comparable as
// you scrub; the early chain (a few thousand tx at most) gets a shorter axis.
export function axisDecades(maxTx) {
  if (!Number.isFinite(maxTx) || maxTx < 0) return MAX_DECADES
  const d = Math.ceil(log10Scale(maxTx) + 0.25)
  return Math.min(MAX_DECADES, Math.max(MIN_DECADES, d))
}

// The largest tx count in a decoded tile, or null with no tile.
export function tileTxMax(tile) {
  if (!tile || !Array.isArray(tile.records)) return null
  let max = 0
  for (const r of tile.records) {
    const n = tile.level === 0 ? r.numTx : r.txMax
    if (n > max) max = n
  }
  return max
}

// The visible height range [h0, h1] in whole blocks: at least `minSpan`
// blocks wide (or the whole chain, if shorter) and inside [0, tip].
export function clampView(h0, h1, tip, minSpan) {
  const t = Math.max(0, Math.floor(tip))
  let a = Math.round(h0)
  let b = Math.round(h1)
  const span = Math.max(Math.min(minSpan, t + 1), Math.min(t + 1, b - a + 1))
  b = a + span - 1
  if (a < 0) {
    a = 0
    b = span - 1
  }
  if (b > t) {
    b = t
    a = Math.max(0, b - span + 1)
  }
  return { h0: a, h1: b }
}
