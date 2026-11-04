// Camera framing and level of detail for /block-graph, kept pure so they can
// be tested without three.js.

// Share of the canvas the graph should fill when it's framed.
const FILL = 0.85

// Detail levels, as a ratio of the camera's distance to the framed distance.
// A fresh load sits at 1.0, so it always shows transactions; zooming out past
// FAR collapses to block boxes, zooming in past CLOSE shows every edge.
const FAR = 1.8
const CLOSE = 0.55

// The camera distance at which a box of this size fills about 85% of the
// canvas, for a perspective camera with this vertical field of view (degrees)
// and aspect ratio (width / height). Fits whichever dimension is tighter.
export function fitDistance(size, fovDeg, aspect) {
  const vFov = (fovDeg * Math.PI) / 180
  const hFov = 2 * Math.atan(Math.tan(vFov / 2) * aspect)

  const forHeight = size.y / 2 / Math.tan(vFov / 2)
  const forWidth = size.x / 2 / Math.tan(hFov / 2)
  const dist = Math.max(forHeight, forWidth) / FILL + (size.z || 0) / 2

  // An empty or single-point layout still needs somewhere to stand.
  return Math.max(dist, 20)
}

// "far" | "medium" | "close" for a camera at `dist` from its target, given the
// distance the graph was framed at.
export function lodLevel(dist, framedDist) {
  const ratio = dist / Math.max(framedDist, 1)
  if (ratio > FAR) return "far"
  if (ratio > CLOSE) return "medium"
  return "close"
}
