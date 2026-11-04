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
