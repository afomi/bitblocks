import { test } from "node:test"
import assert from "node:assert/strict"
import { fitDistance, lodLevel } from "./framing.mjs"

// Blocks 0–100 in the time layout span about 800 units along x.
const range0to100 = { x: 800, y: 40, z: 10 }

test("framing fills most of a wide canvas, not half of it", () => {
  const fov = 60
  const aspect = 2
  const dist = fitDistance(range0to100, fov, aspect)

  // Visible width at that distance, for the horizontal field of view.
  const vFov = (fov * Math.PI) / 180
  const hFov = 2 * Math.atan(Math.tan(vFov / 2) * aspect)
  const visibleWidth = 2 * (dist - range0to100.z / 2) * Math.tan(hFov / 2)

  assert.ok(range0to100.x / visibleWidth > 0.8, `content fills ${range0to100.x / visibleWidth}`)
  assert.ok(range0to100.x / visibleWidth <= 1, "content fits")
})

test("a tall layout is framed by the vertical field of view", () => {
  const dist = fitDistance({ x: 10, y: 400, z: 0 }, 60, 2)
  const visibleHeight = 2 * dist * Math.tan(Math.PI / 6)
  assert.ok(400 / visibleHeight > 0.8 && 400 / visibleHeight <= 1)
})

test("a freshly framed graph shows transactions, whatever its size", () => {
  for (const width of [50, 800, 8000]) {
    const fit = fitDistance({ x: width, y: 40, z: 10 }, 60, 2)
    assert.notEqual(lodLevel(fit, fit), "far", `width ${width}`)
  }
})

test("zooming out past the framed view collapses to blocks, zooming in shows full detail", () => {
  assert.equal(lodLevel(2000, 800), "far")
  assert.equal(lodLevel(300, 800), "close")
})

test("an empty or degenerate box still gets a usable distance", () => {
  const dist = fitDistance({ x: 0, y: 0, z: 0 }, 60, 1.5)
  assert.ok(Number.isFinite(dist) && dist > 0)
})
