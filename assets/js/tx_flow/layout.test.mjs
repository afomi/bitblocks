import { test, describe } from "node:test"
import assert from "node:assert/strict"
import * as layout from "./layout.mjs"

// Blocks 0..3: three coinbases, then block 3 spends block 1's coinbase into
// two outputs, one of which block 3's second tx spends at once.
const payload = {
  from: 0,
  to: 3,
  truncated: false,
  spends_known_through: 3,
  blocks: [
    [0, 100, 1, 1],
    [1, 200, 1, 1],
    [2, 300, 1, 1],
    [3, 400, 3, 3]
  ],
  txs: [
    [0, "g", 1, 0, 5e9],
    [1, "a", 1, 0, 5e9],
    [2, "b", 1, 0, 5e9],
    [3, "c", 1, 0, 5e9],
    [3, "d", 0, 1, 5e9],
    [3, "e", 0, 1, 1e9]
  ],
  outputs: [
    [[5e9, -1]],
    [[5e9, 3]],
    [[5e9, -1]],
    [[5e9, -1]],
    [[4e9, -1], [1e9, 3]],
    [[1e9, -1]]
  ],
  edges: [
    [1, 0, 4, 5e9],
    [4, 1, 5, 1e9]
  ],
  external: []
}

describe("placement", () => {
  test("is fixed by the data: the same payload lands in the same place", () => {
    const a = layout.decode(payload)
    const b = layout.decode(JSON.parse(JSON.stringify(payload)))
    assert.deepEqual([...a.txPos], [...b.txPos])
    assert.deepEqual([...a.outPos], [...b.outPos])
  })

  test("height runs along x and a block's first tx sits on the spine", () => {
    const f = layout.decode(payload)
    assert.equal(f.txPos[0], 0)
    assert.equal(f.txPos[3 * 3], 3 * f.gap)
    assert.deepEqual([f.txPos[3 * 3 + 1], f.txPos[3 * 3 + 2]], [0, 0])
    // The second tx of block 3 is off the spine.
    assert.notEqual(Math.hypot(f.txPos[4 * 3 + 1], f.txPos[4 * 3 + 2]), 0)
  })

  test("the range spans WORLD_LENGTH within the gap bounds", () => {
    assert.equal(layout.gapFor(0, 999), layout.WORLD_LENGTH / 1000)
    assert.equal(layout.gapFor(0, 0), 4)
    assert.equal(layout.gapFor(0, 1e8), 0.02)
  })

  test("an arc starts and ends on its points and rises in the middle", () => {
    const pts = layout.arcPoints([0, 0, 0], [10, 0, 0], 5, 4)
    assert.deepEqual(pts[0], [0, 0, 0])
    assert.deepEqual(pts[4], [10, 0, 0])
    assert.ok(pts[2][1] > 0)
  })
})

describe("the playhead", () => {
  const f = layout.decode(payload)
  const prepared = layout.prepareStats(f)

  test("before the first spend every output is alive", () => {
    const s = layout.statsAt(prepared, 2)
    assert.deepEqual(s, {txs: 3, spends: 0, outputs: 3, alive: 3, aliveSats: 15e9})
  })

  test("a spend retires its output in the block that spends it", () => {
    const s = layout.statsAt(prepared, 3)
    assert.equal(s.txs, 6)
    assert.equal(s.spends, 2)
    assert.equal(s.outputs, 7)
    assert.equal(s.alive, 5)
    // 4 coinbases (20e9) + d's two outputs (5e9) + e's (1e9), less the two spent (5e9 + 1e9).
    assert.equal(s.aliveSats, 20e9)
  })

  test("the first spend is the lowest spending height", () => {
    assert.equal(layout.firstSpend(f).height, 3)
  })
})

describe("lineage", () => {
  const f = layout.decode(payload)

  test("reaches ancestors and descendants, not unrelated txs", () => {
    const {txs, edges} = layout.lineage(f, 4)
    assert.deepEqual([...txs].sort(), [1, 4, 5])
    assert.deepEqual([...edges].sort(), [0, 1])
  })

  test("of a lone coinbase is itself", () => {
    const {txs, edges} = layout.lineage(f, 0)
    assert.deepEqual([...txs], [0])
    assert.equal(edges.size, 0)
  })
})

describe("external sources", () => {
  test("an input from outside the range starts on the spine at its height", () => {
    const f = layout.decode({
      ...payload,
      from: 2,
      txs: payload.txs.slice(2),
      outputs: payload.outputs.slice(2),
      edges: [[-1, 0, 2, 5e9]],
      external: [["a", 1]]
    })
    const [edge] = f.edges
    assert.equal(edge.sourceHeight, 1)
    assert.deepEqual(layout.edgeSource(f, edge), [-f.gap, 0, 0])
  })

  test("an external txid that is loaded after all is drawn from its output", () => {
    const f = layout.decode({...payload, edges: [[-1, 0, 4, 5e9]], external: [["a", 1]]})
    assert.equal(f.edges[0].src, 1)
  })

  test("geometry has two vertices per arc segment", () => {
    const f = layout.decode(payload)
    const g = layout.edgeGeometry(f)
    assert.equal(g.count, 2 * layout.ARC_SEGMENTS * 2)
    assert.equal(g.born[0], 3)
  })
})

// A flow tile as lib/bitblocks/flow_tiles/codec.ex writes it.
function flowTile(firstHeight, records) {
  const buf = new ArrayBuffer(32 + records.length * 96)
  const v = new DataView(buf)
  "BBF1".split("").forEach((c, i) => v.setUint8(i, c.charCodeAt(0)))
  v.setUint8(4, 1)
  v.setUint8(5, 16)
  v.setUint16(6, 96, true)
  v.setUint32(8, firstHeight, true)
  v.setUint32(12, records.length, true)
  records.forEach((r, i) => {
    const o = 32 + i * 96
    v.setUint32(o, r.time || 0, true)
    v.setUint32(o + 4, r.numTx || 0, true)
    v.setUint32(o + 8, r.stored || 0, true)
    v.setUint32(o + 12, r.nIn || 0, true)
    v.setUint32(o + 16, r.nOut || 0, true)
    v.setUint32(o + 20, r.unknown || 0, true)
    v.setFloat64(o + 24, r.satsOut || 0, true)
    for (const [b, n] of Object.entries(r.hist || {})) v.setUint32(o + 32 + Number(b) * 4, n, true)
  })
  return buf
}

describe("flow tiles", () => {
  const records = []
  for (let h = 0; h < 200; h++) records.push({time: 1000 + h, numTx: 1, stored: 1, nOut: 1, satsOut: 5e9})
  records[170] = {time: 1170, numTx: 2, stored: 2, nIn: 1, nOut: 3, satsOut: 1e10, hist: {8: 1}}
  records[10] = {} // not built
  const tile = layout.decodeFlowTile(flowTile(0, records))

  test("decodes a tile's records", () => {
    assert.equal(tile.firstHeight, 0)
    assert.equal(tile.count, 200)
    assert.equal(tile.nIn[170], 1)
    assert.equal(tile.hist[170 * 16 + 8], 1)
    assert.equal(tile.satsOut[170], 1e10)
  })

  test("rejects bytes that aren't a flow tile", () => {
    assert.throws(() => layout.decodeFlowTile(new ArrayBuffer(32)))
  })

  test("picks the built tiles a range needs", () => {
    const manifest = {tile_records: 1024, built_through: 2100, tiles: ["a", null, "c"]}
    assert.deepEqual(layout.tilesForRange(manifest, 0, 5000), [
      {idx: 0, hash: "a"},
      {idx: 2, hash: "c"}
    ])
    assert.deepEqual(layout.tilesForRange(manifest, 3000, 5000), [])
  })

  test("one node per built block, one arc per age bin, drawn back by that age", () => {
    const flow = layout.summaryFlow([tile], 0, 199, {builtThrough: 199})
    assert.equal(flow.summary, true)
    assert.equal(flow.group, 1)
    assert.equal(flow.n, 199) // block 10 isn't built
    assert.equal(layout.summaryTxCount([tile], 0, 199), 200)
    assert.equal(flow.edges.length, 1)
    const [edge] = flow.edges
    assert.equal(flow.txHeight[edge.dst], 170)
    assert.equal(edge.sourceHeight, 170 - layout.binAge(8))
    assert.ok(layout.binAge(8) >= 128 && layout.binAge(8) < 256)
    assert.equal(edge.weight, 1)

    const stats = layout.summaryStats(flow)
    assert.deepEqual(layout.summaryStatsAt(stats, 169), {txs: 169, spends: 0, outputs: 169})
    assert.deepEqual(layout.summaryStatsAt(stats, 170), {txs: 171, spends: 1, outputs: 172})
    assert.equal(layout.nodeAt(flow, 170).nIn, 1)

    // The scene's arc geometry takes the summary as it is.
    const geo = layout.edgeGeometry(flow, layout.SUMMARY_ARC_SEGMENTS)
    assert.equal(geo.count, layout.SUMMARY_ARC_SEGMENTS * 2)
    assert.equal(geo.weight[0], 1)
  })

  test("a long range groups blocks into at most maxNodes nodes, keeping the sums", () => {
    const flow = layout.summaryFlow([tile], 0, 199, {maxNodes: 20})
    assert.equal(flow.group, 10)
    assert.equal(flow.n, 20)
    const node = layout.nodeAt(flow, 175)
    assert.equal(node.height, 170)
    assert.equal(node.last, 179)
    assert.equal(node.stored, 11)
    assert.equal(node.nIn, 1)
    assert.equal(flow.nodes.reduce((s, n) => s + n.stored, 0), 200)
  })
})
