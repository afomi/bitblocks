// Pure logic for the transaction flow space (/tx-graph): decoding the
// ChainFlow payload, placing every tx and output, the arcs between them, and
// what is true at a playhead height. No three.js, no DOM, so it runs under
// `node --test` (layout.test.mjs).
//
// Placement is fixed by the data alone and never re-solved, so a tx sits in
// the same place on every load and scrubbing never moves a node:
//   - height runs along x, one `gap` per block;
//   - a block's txs fill a sunflower disc in the y/z plane around the spine,
//     the coinbase at its centre and tx k at radius ~ sqrt(k), angle k * the
//     golden angle;
//   - an output sits just off its tx, on its own small sunflower;
//   - an input is an arc from the output it spends to the tx spending it,
//     lifted by the log of the coins' age in blocks.

export const GOLDEN_ANGLE = Math.PI * (3 - Math.sqrt(5))
export const NEVER = 1e9 // "not spent (as far as we have synced)"
export const ARC_SEGMENTS = 16
export const WORLD_LENGTH = 400 // the loaded range spans this many units

// The block gap that makes the range WORLD_LENGTH long, within bounds so one
// block is never a hair and a short range never a mile.
export function gapFor(from, to) {
  const span = Math.max(1, to - from + 1)
  return Math.min(4, Math.max(0.02, WORLD_LENGTH / span))
}

// The disc a block of n txs fills: grows with sqrt(n), so area tracks count.
export function discRadius(n, gap) {
  return Math.min(60, Math.max(gap * 0.3, Math.sqrt(Math.max(1, n)) * gap * 0.22))
}

// Where the k-th tx of a block of n sits on its disc (y, z).
export function discPoint(k, n, radius) {
  if (k === 0 || n <= 1) return [0, 0]
  const r = radius * Math.sqrt(k / (n - 1))
  const a = k * GOLDEN_ANGLE
  return [r * Math.cos(a), r * Math.sin(a)]
}

// log10 of a value in sats, as a node size in [0.6, 2.2].
export function sizeFor(sats) {
  if (!(sats > 0)) return 0.6
  return 0.6 + Math.min(1.6, Math.log10(1 + sats / 1e5) / 4)
}

// The lift of an arc that moves coins `age` blocks.
export function liftFor(age, gap) {
  return gap * 2 + Math.log2(1 + Math.max(0, age)) * Math.max(0.6, gap * 1.2)
}

// Points along a quadratic arc from a to b, raised by lift at its middle.
export function arcPoints(a, b, lift, segments = ARC_SEGMENTS) {
  const mid = [(a[0] + b[0]) / 2, Math.max(a[1], b[1]) + lift, (a[2] + b[2]) / 2]
  const out = []
  for (let i = 0; i <= segments; i++) {
    const t = i / segments
    const u = 1 - t
    out.push([
      u * u * a[0] + 2 * u * t * mid[0] + t * t * b[0],
      u * u * a[1] + 2 * u * t * mid[1] + t * t * b[1],
      u * u * a[2] + 2 * u * t * mid[2] + t * t * b[2]
    ])
  }
  return out
}

// Index of the first element of sorted `arr` greater than x.
export function upperBound(arr, x) {
  let lo = 0
  let hi = arr.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (arr[mid] <= x) lo = mid + 1
    else hi = mid
  }
  return lo
}

// Decodes a ChainFlow payload (see lib/bitblocks/chain_flow.ex) into flat
// arrays the scene can upload as they are, plus the indexes the stats and the
// lineage need.
export function decode(payload) {
  const from = payload.from
  const to = payload.to
  const gap = gapFor(from, to)
  const txs = payload.txs || []
  const outputs = payload.outputs || []
  const external = payload.external || []

  const perBlock = new Map()
  for (const [h] of txs) perBlock.set(h, (perBlock.get(h) || 0) + 1)

  // Tx positions.
  const n = txs.length
  const txPos = new Float32Array(n * 3)
  const txHeight = new Float32Array(n)
  const txSize = new Float32Array(n)
  const txCoinbase = new Uint8Array(n)
  const txIndex = new Map()
  const seen = new Map()
  for (let i = 0; i < n; i++) {
    const [h, txid, cb, , satsOut] = txs[i]
    const k = seen.get(h) || 0
    seen.set(h, k + 1)
    const count = perBlock.get(h)
    const [y, z] = discPoint(k, count, discRadius(count, gap))
    txPos[i * 3] = (h - from) * gap
    txPos[i * 3 + 1] = y
    txPos[i * 3 + 2] = z
    txHeight[i] = h
    txSize[i] = sizeFor(satsOut)
    txCoinbase[i] = cb
    txIndex.set(txid, i)
  }

  // Outputs: a small sunflower around their tx, offset along +x so the
  // coinbase output doesn't hide under its tx.
  let outCount = 0
  for (const list of outputs) outCount += list.length
  const outPos = new Float32Array(outCount * 3)
  const outBorn = new Float32Array(outCount)
  const outSpent = new Float32Array(outCount)
  const outSats = new Float64Array(outCount)
  const outOffset = new Int32Array(n + 1)
  const spread = Math.min(1.2, gap * 0.18)
  let o = 0
  for (let i = 0; i < n; i++) {
    outOffset[i] = o
    const list = outputs[i] || []
    for (let j = 0; j < list.length; j++) {
      const [sats, spentAt] = list[j]
      const [dy, dz] = discPoint(j + 1, list.length + 1, spread * Math.sqrt(list.length))
      outPos[o * 3] = txPos[i * 3] + spread * 0.5
      outPos[o * 3 + 1] = txPos[i * 3 + 1] + dy
      outPos[o * 3 + 2] = txPos[i * 3 + 2] + dz
      outBorn[o] = txHeight[i]
      outSpent[o] = spentAt >= 0 ? spentAt : NEVER
      outSats[o] = sats > 0 ? sats : 0
      o++
    }
  }
  outOffset[n] = o

  // Edges: from the output spent (or the external source) to the spender.
  const edges = []
  for (const [src, vout, dst, sats] of payload.edges || []) {
    let s = src
    let sourceHeight
    if (s < 0) {
      const ext = external[-1 - s]
      const local = ext && txIndex.get(ext[0])
      if (local !== undefined) s = local
      else sourceHeight = ext && ext[1] >= 0 ? ext[1] : null
    }
    edges.push({src: s, vout, dst, sats, sourceHeight: s >= 0 ? txHeight[s] : sourceHeight})
  }

  return {
    from,
    to,
    gap,
    truncated: !!payload.truncated,
    spendsKnownThrough: payload.spends_known_through,
    blocks: payload.blocks || [],
    txs,
    external,
    n,
    txPos,
    txHeight,
    txSize,
    txCoinbase,
    txIndex,
    outCount,
    outPos,
    outBorn,
    outSpent,
    outSats,
    outOffset,
    edges
  }
}

// The point an edge starts from: the spent output when it is loaded, else a
// point on the spine at the source's height (left of the range when older).
export function edgeSource(flow, edge) {
  if (edge.src >= 0) {
    const o = flow.outOffset[edge.src] + edge.vout
    if (o < flow.outOffset[edge.src + 1]) {
      return [flow.outPos[o * 3], flow.outPos[o * 3 + 1], flow.outPos[o * 3 + 2]]
    }
    return [flow.txPos[edge.src * 3], flow.txPos[edge.src * 3 + 1], flow.txPos[edge.src * 3 + 2]]
  }
  const h = edge.sourceHeight == null ? flow.from - 1 : edge.sourceHeight
  return [(h - flow.from) * flow.gap, 0, 0]
}

// Line-segment vertices for every edge: positions, the height it was spent
// at (born), and t along the arc for the flow shimmer.
export function edgeGeometry(flow) {
  const segs = ARC_SEGMENTS
  const count = flow.edges.length * segs * 2
  const pos = new Float32Array(count * 3)
  const born = new Float32Array(count)
  const along = new Float32Array(count)
  const edgeOf = new Int32Array(count)
  let v = 0
  flow.edges.forEach((edge, e) => {
    const a = edgeSource(flow, edge)
    const d = edge.dst
    const b = [flow.txPos[d * 3], flow.txPos[d * 3 + 1], flow.txPos[d * 3 + 2]]
    const h = flow.txHeight[d]
    const age = edge.sourceHeight == null ? 0 : h - edge.sourceHeight
    const pts = arcPoints(a, b, liftFor(age, flow.gap), segs)
    for (let i = 0; i < segs; i++) {
      for (const j of [i, i + 1]) {
        pos[v * 3] = pts[j][0]
        pos[v * 3 + 1] = pts[j][1]
        pos[v * 3 + 2] = pts[j][2]
        born[v] = h
        along[v] = j / segs
        edgeOf[v] = e
        v++
      }
    }
  })
  return {pos, born, along, edgeOf, count}
}

// What is true at playhead height `h`: txs mined, spends made, and outputs
// alive (created and not yet spent), with their value. O(log n) per call once
// `prepareStats` has sorted the heights.
export function prepareStats(flow) {
  const txHeights = Float64Array.from(flow.txHeight).sort()
  const spendHeights = Float64Array.from(flow.edges.map((e) => flow.txHeight[e.dst])).sort()
  const outBorn = Float64Array.from(flow.outBorn).sort()

  // Outputs spent within what we know, sorted by spent height, with a prefix
  // sum of value; and outputs by born height with a prefix sum of value.
  const bornOrder = [...flow.outBorn.keys()].sort((a, b) => flow.outBorn[a] - flow.outBorn[b])
  const bornSats = new Float64Array(bornOrder.length + 1)
  bornOrder.forEach((o, i) => (bornSats[i + 1] = bornSats[i] + flow.outSats[o]))
  const spentOrder = [...flow.outSpent.keys()]
    .filter((o) => flow.outSpent[o] < NEVER)
    .sort((a, b) => flow.outSpent[a] - flow.outSpent[b])
  const outSpent = Float64Array.from(spentOrder.map((o) => flow.outSpent[o]))
  const spentSats = new Float64Array(spentOrder.length + 1)
  spentOrder.forEach((o, i) => (spentSats[i + 1] = spentSats[i] + flow.outSats[o]))

  return {txHeights, spendHeights, outBorn, outSpent, bornSats, spentSats}
}

export function statsAt(prepared, h) {
  const txs = upperBound(prepared.txHeights, h)
  const spends = upperBound(prepared.spendHeights, h)
  const born = upperBound(prepared.outBorn, h)
  const spent = upperBound(prepared.outSpent, h)
  return {
    txs,
    spends,
    outputs: born,
    alive: born - spent,
    aliveSats: prepared.bornSats[born] - prepared.spentSats[spent]
  }
}

// Every tx connected to `start` through loaded edges: its ancestors (the txs
// whose outputs it spends, and theirs) and its descendants. Returns a Set of
// tx indexes and a Set of edge indexes.
export function lineage(flow, start) {
  const parents = new Map()
  const children = new Map()
  flow.edges.forEach((e, i) => {
    if (e.src < 0) return
    if (!parents.has(e.dst)) parents.set(e.dst, [])
    parents.get(e.dst).push([e.src, i])
    if (!children.has(e.src)) children.set(e.src, [])
    children.get(e.src).push([e.dst, i])
  })
  const txs = new Set([start])
  const edgeSet = new Set()
  flow.edges.forEach((e, i) => {
    if (e.dst === start && e.src < 0) edgeSet.add(i)
  })
  for (const links of [parents, children]) {
    const stack = [start]
    const seen = new Set([start])
    while (stack.length) {
      const t = stack.pop()
      for (const [next, i] of links.get(t) || []) {
        edgeSet.add(i)
        if (!seen.has(next)) {
          seen.add(next)
          txs.add(next)
          stack.push(next)
        }
      }
    }
  }
  return {txs, edges: edgeSet}
}

// The first spend in the range: the lowest-height edge from a loaded output.
export function firstSpend(flow) {
  let best = null
  for (const e of flow.edges) {
    const h = flow.txHeight[e.dst]
    if (best === null || h < best.height) best = {height: h, edge: e}
  }
  return best
}

// Formatting shared with the readout.
export function fmtCoins(sats) {
  const coins = sats / 1e8
  if (coins >= 1000) return Math.round(coins).toLocaleString("en-US")
  return coins.toLocaleString("en-US", {maximumFractionDigits: 8})
}
