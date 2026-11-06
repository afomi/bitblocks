// ChainScrubber — scrub the chain from genesis to tip, one block height per
// scrubber position. Height is the axis. The chain is drawn from precomputed
// binary tiles (see ../chain_scrubber/tiles.mjs) at a resolution level picked
// by the viewport, never one object per block.
//
// Column height = log10(num_tx + 1); depth = log10(size_bytes + 1).
// A block that is not `completed` is a GAP and draws red, at its header tx
// count, so a block keeps its height at every zoom level.
// Rollups draw the largest block in the bucket (so spikes survive) with a thin
// inner column for the mean, and mix toward red by the share of gaps.
// The axis spans the chain's largest block (tiles.axisDecades), fixed while
// scrubbing; the early chain gets a shorter axis instead of flat columns.
// Motion is secondary: still scene, hand-scrubbed; reduced-motion disables the
// view easing and auto-play.

import * as THREE from "three"
import * as tiles from "../chain_scrubber/tiles.mjs"

const WIDTH = 100 // world units across the viewport, always [h0, h1]
const MAX_INSTANCES = 4352 // 4096 budget + alignment slack
const Z_SCALE = 0.45 // depth per log10(bytes + 1)
const GAP_HEIGHT = 0.25
const MIN_SPAN = 16
const MAX_IN_FLIGHT = 6
const MAX_CACHED_TILES = 1200
const REST_MS = 300
const PLAY_MS = 250
const EASE_MS = 220
const DRAG_PX = 4

const COLORS = {
  completed: new THREE.Color(0x3b82f6),
  gap: new THREE.Color(0x7f1d1d),
  missing: new THREE.Color(0x4a1010),
  mean: new THREE.Color(0x93c5fd),
  current: new THREE.Color(0xf59e0b),
  reorg: new THREE.Color(0x8b5cf6),
  loss: new THREE.Color(0xef4444),
  burn: new THREE.Color(0xf97316),
  event: new THREE.Color(0xffffff),
  // The scene stays near-black in light and dark mode: it is the one dark
  // region on the page, framed by site-style chrome (DESIGN.md). Keep it in
  // step with #chain-scrubber's bg-[#050608] in chain_scrubber_live.html.heex.
  background: 0x050608,
  ground: 0x111827
}

// Chain annotations (Bitblocks.Annotations), coloured per kind; the same
// hues as the kind pills on /annotations.
const EVENT_COLORS = {
  fork: new THREE.Color(0xa78bfa),
  upgrade: new THREE.Color(0x38bdf8),
  halving: new THREE.Color(0xfbbf24),
  milestone: new THREE.Color(0x34d399),
  mint: new THREE.Color(0xf472b6),
  world: new THREE.Color(0xe5e7eb),
  note: new THREE.Color(0x60a5fa)
}

const MARKER_KINDS = ["reorg", "loss", "burn", "event"]

function markerKind(kind) {
  return kind === "reorg" || kind === "loss" || kind === "burn" ? kind : "event"
}

const MARK_COLORS = {
  coinbase: "#f59e0b",
  protocol: "#22c55e",
  plain: "#6b7280"
}

function escapeHtml(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

function fmtInt(n) {
  return Number.isFinite(n) ? Math.round(n).toLocaleString("en-US") : "…"
}

function fmtBytes(b) {
  if (!Number.isFinite(b)) return "…"
  const units = ["B", "KB", "MB", "GB", "TB"]
  let i = 0
  let v = b
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i++
  }
  return `${i === 0 ? Math.round(v) : v.toFixed(v >= 100 ? 0 : 1)} ${units[i]}`
}

function fmtTime(t) {
  if (!Number.isFinite(t) || t <= 0) return "—"
  return new Date(t * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC"
}

function fmtSats(sats) {
  if (!Number.isFinite(sats)) return "? sats"
  if (sats >= 1e8) return `${(sats / 1e8).toFixed(sats >= 1e10 ? 0 : 4)} BSV`
  return `${fmtInt(sats)} sats`
}

function isTextInput(target) {
  if (!target || !target.tagName) return false
  const tag = target.tagName.toLowerCase()
  if (tag === "textarea" || tag === "select") return true
  if (target.isContentEditable) return true
  if (tag === "input") return (target.getAttribute("type") || "text") !== "range"
  return false
}

export default {
  mounted() {
    const ds = this.el.dataset
    this.manifestUrl = ds.manifestUrl || "/chain-scrubber/tiles/manifest"
    this.tileBase = ds.tileBase || "/chain-scrubber/tiles"
    this.tip = Math.max(0, parseInt(ds.tipHeight, 10) || 0)
    this.height = tiles.step(parseInt(ds.height, 10) || 0, 0, this.tip)
    // ?from=&to= opens on a stretch of the chain; the axis fits that stretch.
    const vf = parseInt(ds.viewFrom, 10)
    const vt = parseInt(ds.viewTo, 10)
    this.framed = Number.isFinite(vf) && Number.isFinite(vt) && vt > vf && (vf > 0 || vt < this.tip)
    this.view = this.framed ? tiles.clampView(vf, vt, this.tip, MIN_SPAN) : {h0: 0, h1: this.tip}
    this.frame = {...this.view}
    this.level = tiles.levelFor(this.view.h1 - this.view.h0 + 1)
    this.decades = tiles.MAX_DECADES
    this.manifest = null
    this.manifestRefreshed = false
    this.tileCache = new Map() // `${level}/${idx}` -> decoded tile | null (absent)
    this.tilePending = new Map() // key -> Promise
    this.queue = []
    this.inFlight = 0
    this.annotations = []
    this.markerRefs = {reorg: [], loss: [], burn: [], event: []}
    this.instanceHeights = [] // instance index -> record height
    this.instanceBaseColors = [] // instance index -> THREE.Color
    this.highlightedInstance = -1
    this.restTimer = null
    this.lastRestHeight = null
    this.playTimer = null
    this.easeFrame = null
    this.renderQueued = false
    this.statusNote = ""
    this.loadingTiles = 0
    this.alive = true
    this.motionQuery =
      typeof window.matchMedia === "function" ? window.matchMedia("(prefers-reduced-motion: reduce)") : null
    this.reducedMotion = !!(this.motionQuery && this.motionQuery.matches)
    this.onMotionChange = (e) => {
      this.reducedMotion = e.matches
      if (e.matches) this.stopPlay()
    }
    if (this.motionQuery && this.motionQuery.addEventListener) {
      this.motionQuery.addEventListener("change", this.onMotionChange)
    }

    this.els = {
      canvas: this.el.querySelector("#chain-scrubber-canvas") || this.el.querySelector("canvas"),
      detail: this.el.querySelector("#chain-scrubber-detail"),
      markerTip: this.el.querySelector("#chain-scrubber-marker-tip"),
      range: this.el.querySelector("#chain-scrubber-range"),
      readout: {}
    }
    for (const span of this.el.querySelectorAll("[data-readout]")) {
      this.els.readout[span.dataset.readout] = span
    }

    if (!this.els.canvas) {
      this.setStatus("No canvas element found.")
      return
    }

    this.setupScene()
    this.bindControls()

    this.handleEvent("jump", ({height}) => {
      // Leave the jump field so the arrow keys step from the new height at once.
      const jump = document.getElementById("chain-scrubber-jump")
      if (jump && document.activeElement === jump) jump.blur()
      this.setHeight(height)
    })
    this.handleEvent("annotations", ({items}) => this.setAnnotations(items || []))
    this.handleEvent("rest_data", (payload) => this.renderDetail(payload))

    this.updateRange()
    this.updateReadoutLevel()
    // Live: the sync completes blocks all the time, and the tile build folds
    // them in every 5 minutes. Re-read the manifest each minute while the tab
    // is visible and refetch only the tiles whose hash moved.
    this.liveTimer = setInterval(() => {
      if (document.visibilityState === "visible") this.refreshLive()
    }, 60_000)
    this.setStatus("Loading tile manifest…")

    this.loadManifest().then((ok) => {
      if (!this.alive) return
      if (!ok) return
      this.setStatus("")
      this.refreshView()
      this.setHeight(this.height)
      this.loadAxis()
    })
  },

  destroyed() {
    this.alive = false
    clearInterval(this.liveTimer)
    this.stopPlay()
    if (this.restTimer) clearTimeout(this.restTimer)
    if (this.easeFrame) cancelAnimationFrame(this.easeFrame)
    if (this.renderFrame) cancelAnimationFrame(this.renderFrame)
    if (this.resizeObserver) this.resizeObserver.disconnect()
    window.removeEventListener("resize", this.onResize)
    if (this.motionQuery && this.motionQuery.removeEventListener) {
      this.motionQuery.removeEventListener("change", this.onMotionChange)
    }
    window.removeEventListener("keydown", this.onKeyDown)
    window.removeEventListener("pointermove", this.onPointerMove)
    window.removeEventListener("pointerup", this.onPointerUp)
    const c = this.els.canvas
    if (c) {
      c.removeEventListener("wheel", this.onWheel)
      c.removeEventListener("pointerdown", this.onPointerDown)
    }
    for (const [el, type, fn] of this.boundListeners || []) el.removeEventListener(type, fn)
    this.queue = []
    this.tileCache.clear()
    this.tilePending.clear()

    if (this.columns) this.disposeInstanced(this.columns)
    if (this.means) this.disposeInstanced(this.means)
    if (this.markers) {
      this.disposeInstanced(this.markers.reorg)
      this.disposeInstanced(this.markers.loss)
      this.disposeInstanced(this.markers.burn)
      this.disposeInstanced(this.markers.event)
    }
    if (this.cursor) {
      this.cursor.geometry.dispose()
      this.cursor.material.dispose()
    }
    if (this.ground) {
      this.ground.geometry.dispose()
      this.ground.material.dispose()
    }
    if (this.renderer) {
      this.renderer.dispose()
      if (this.renderer.forceContextLoss) this.renderer.forceContextLoss()
    }
  },

  disposeInstanced(mesh) {
    if (!mesh) return
    mesh.geometry.dispose()
    mesh.material.dispose()
    mesh.dispose()
  },

  // ---------------------------------------------------------------- scene

  setupScene() {
    const canvas = this.els.canvas
    this.renderer = new THREE.WebGLRenderer({canvas, antialias: true, alpha: false})
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
    this.renderer.setClearColor(COLORS.background, 1)

    this.scene = new THREE.Scene()
    this.camera = new THREE.OrthographicCamera(-WIDTH / 2, WIDTH / 2, 10, -10, 0.1, 1000)

    this.scene.add(new THREE.AmbientLight(0xffffff, 0.75))
    const sun = new THREE.DirectionalLight(0xffffff, 1.1)
    sun.position.set(-30, 60, 80)
    this.scene.add(sun)

    const box = new THREE.BoxGeometry(1, 1, 1)
    box.translate(0, 0.5, 0) // grow from the ground
    this.columns = new THREE.InstancedMesh(box, new THREE.MeshLambertMaterial(), MAX_INSTANCES)
    this.columns.count = 0
    this.columns.frustumCulled = false
    this.scene.add(this.columns)

    this.means = new THREE.InstancedMesh(box.clone(), new THREE.MeshLambertMaterial(), MAX_INSTANCES)
    this.means.count = 0
    this.means.frustumCulled = false
    this.scene.add(this.means)

    const diamond = new THREE.OctahedronGeometry(1, 0)
    this.markers = {
      reorg: new THREE.InstancedMesh(diamond, new THREE.MeshLambertMaterial({color: COLORS.reorg}), 1),
      loss: new THREE.InstancedMesh(diamond.clone(), new THREE.MeshLambertMaterial({color: COLORS.loss}), 1),
      burn: new THREE.InstancedMesh(diamond.clone(), new THREE.MeshLambertMaterial({color: COLORS.burn}), 1),
      event: new THREE.InstancedMesh(diamond.clone(), new THREE.MeshLambertMaterial({color: COLORS.event}), 1)
    }
    for (const m of Object.values(this.markers)) {
      m.count = 0
      m.frustumCulled = false
      this.scene.add(m)
    }

    this.cursor = new THREE.Mesh(
      box.clone(),
      new THREE.MeshBasicMaterial({color: COLORS.current, transparent: true, opacity: 0.35, depthWrite: false})
    )
    this.cursor.visible = false
    this.scene.add(this.cursor)

    this.ground = new THREE.Mesh(
      new THREE.PlaneGeometry(WIDTH * 1.2, 40),
      new THREE.MeshBasicMaterial({color: COLORS.ground})
    )
    this.ground.rotation.x = -Math.PI / 2
    this.ground.position.set(0, -0.02, 0)
    this.scene.add(this.ground)

    this.raycaster = new THREE.Raycaster()
    this.pointerNdc = new THREE.Vector2()
    this.tmpMatrix = new THREE.Matrix4()
    this.tmpPos = new THREE.Vector3()
    this.tmpQuat = new THREE.Quaternion()
    this.tmpScale = new THREE.Vector3()
    this.tmpColor = new THREE.Color()

    this.onResize = () => this.resize()
    if (typeof ResizeObserver === "function") {
      this.resizeObserver = new ResizeObserver(this.onResize)
      this.resizeObserver.observe(this.el)
    }
    window.addEventListener("resize", this.onResize)
    this.resize()
  },

  canvasSize() {
    const c = this.els.canvas
    const w = c.clientWidth || this.el.clientWidth || 800
    const h = c.clientHeight || Math.round(w * 0.45) || 360
    return {w, h}
  },

  resize() {
    if (!this.renderer) return
    const {w, h} = this.canvasSize()
    this.renderer.setSize(w, h, false)
    const aspect = w / h
    const frustumH = WIDTH / aspect
    this.frustumH = frustumH
    this.yScale = (0.62 * frustumH) / this.decades
    this.yMax = this.decades * this.yScale
    const cy = 0.42 * frustumH
    this.camera.top = frustumH / 2
    this.camera.bottom = -frustumH / 2
    this.camera.position.set(0, cy + 28, 70)
    this.camera.lookAt(0, cy, 0)
    this.camera.updateProjectionMatrix()
    this.rebuildInstances()
  },

  requestRender() {
    if (this.renderQueued || !this.alive) return
    this.renderQueued = true
    this.renderFrame = requestAnimationFrame(() => {
      this.renderQueued = false
      if (!this.alive || !this.renderer) return
      this.renderer.render(this.scene, this.camera)
    })
  },

  // ---------------------------------------------------------------- tiles

  async refreshLive() {
    if (!this.alive || !this.manifest) return
    const before = this.manifest
    if (!(await this.loadManifest())) return
    const changed = tiles.changedTiles(before, this.manifest)
    if (!changed.length) return
    for (const key of changed) this.tileCache.delete(key)
    this.manifestRefreshed = false
    this.refreshView()
  },

  async loadManifest() {
    try {
      const resp = await fetch(this.manifestUrl, {credentials: "same-origin", headers: {accept: "application/json"}})
      if (resp.status === 404) {
        this.manifest = null
        this.setStatus("Tiles not built yet. Run Bitblocks.Release.build_chain_tiles() first.")
        return false
      }
      if (!resp.ok) {
        this.setStatus(`Tile manifest failed (HTTP ${resp.status}).`)
        return false
      }
      const manifest = await resp.json()
      if (!manifest || manifest.version !== 1 || !Array.isArray(manifest.levels)) {
        this.setStatus("Tile manifest is not version 1.")
        return false
      }
      this.manifest = manifest
      if (Number.isFinite(manifest.tip_height) && manifest.tip_height > this.tip) {
        this.tip = manifest.tip_height
        if (!this.framed) this.view.h1 = this.tip
        this.updateRangeBounds()
      }
      // Hashes may have changed: drop tiles we know to be absent so they get retried.
      for (const [key, tile] of this.tileCache) if (tile === null) this.tileCache.delete(key)
      return true
    } catch (err) {
      this.setStatus(`Tile manifest unreachable (${err && err.message ? err.message : err}).`)
      return false
    }
  },

  // Size the column axis to the largest block in the opening frame (the whole
  // chain unless ?from=&to= is given), read from the coarsest level: one tile
  // up to height 33 million at level 3.
  async loadAxis() {
    const levels = (this.manifest.levels || []).filter((l) => l && Array.isArray(l.tiles) && l.tiles.length)
    if (!levels.length) return
    const top = levels.reduce((a, b) => (b.level > a.level ? b : a))
    const loaded = await Promise.all(top.tiles.map((_, idx) => this.fetchTile(top.level, idx)))
    if (!this.alive) return
    const {h0, h1} = this.frame
    const maxes = loaded.map((t) => tiles.tileTxMax(t, h0, h1)).filter((n) => n !== null)
    if (!maxes.length) return
    const decades = tiles.axisDecades(Math.max(...maxes))
    if (decades === this.decades) return
    this.decades = decades
    this.resize()
    this.updateStatus()
  },

  enqueue(fn) {
    return new Promise((resolve, reject) => {
      this.queue.push({fn, resolve, reject})
      this.pump()
    })
  },

  pump() {
    while (this.inFlight < MAX_IN_FLIGHT && this.queue.length) {
      const job = this.queue.shift()
      this.inFlight++
      Promise.resolve()
        .then(job.fn)
        .then(job.resolve, job.reject)
        .finally(() => {
          this.inFlight--
          this.pump()
        })
    }
  },

  cachedTile(level, idx) {
    const t = this.tileCache.get(tiles.tileKey(level, idx))
    return t || null
  },

  fetchTile(level, idx) {
    const key = tiles.tileKey(level, idx)
    if (this.tileCache.has(key)) return Promise.resolve(this.tileCache.get(key))
    if (this.tilePending.has(key)) return this.tilePending.get(key)
    if (!this.manifest) return Promise.resolve(null)

    const url = tiles.tileUrl(this.tileBase, this.manifest, level, idx)
    if (!url) {
      this.tileCache.set(key, null)
      return Promise.resolve(null)
    }

    this.loadingTiles++
    this.updateStatus()
    const get = async (u) => {
      const resp = await fetch(u, {credentials: "same-origin"})
      if (resp.status === 404) return null
      if (!resp.ok) throw new Error(`tile ${key}: HTTP ${resp.status}`)
      return tiles.decodeTile(await resp.arrayBuffer())
    }
    const p = this.enqueue(async () => {
      const tile = await get(url)
      if (tile !== null) return tile
      // 404 means the manifest is stale: refetch it once and retry with the new hash.
      if (this.manifestRefreshed) return null
      this.manifestRefreshed = true
      if (!(await this.loadManifest())) return null
      const retryUrl = tiles.tileUrl(this.tileBase, this.manifest, level, idx)
      return retryUrl ? get(retryUrl) : null
    })
      .then((tile) => {
        this.storeTile(key, tile)
        return tile
      })
      .catch((err) => {
        console.warn("[ChainScrubber]", err)
        this.statusNote = `Tile ${key} failed to load.`
        return null
      })
      .finally(() => {
        this.tilePending.delete(key)
        this.loadingTiles = Math.max(0, this.loadingTiles - 1)
        this.updateStatus()
      })
    this.tilePending.set(key, p)
    return p
  },

  storeTile(key, tile) {
    if (!this.alive) return
    if (tile === undefined) return
    this.tileCache.set(key, tile)
    while (this.tileCache.size > MAX_CACHED_TILES) {
      const oldest = this.tileCache.keys().next().value
      if (oldest === undefined) break
      this.tileCache.delete(oldest)
    }
  },

  recordAt(height, level) {
    const tile = this.cachedTile(level, tiles.tileIndex(height, level))
    if (!tile) return null
    const r = tiles.recordIndex(height, level)
    return r < tile.count ? tile.records[r] : null
  },

  // ---------------------------------------------------------------- view

  clampView(h0, h1) {
    return tiles.clampView(h0, h1, this.tip, MIN_SPAN)
  },

  setView(h0, h1) {
    const v = this.clampView(h0, h1)
    if (v.h0 === this.view.h0 && v.h1 === this.view.h1) return
    this.view = v
    this.refreshView()
  },

  easeViewTo(h0, h1) {
    if (this.easeFrame) cancelAnimationFrame(this.easeFrame)
    const target = this.clampView(h0, h1)
    if (this.reducedMotion) {
      this.setView(target.h0, target.h1)
      return
    }
    const from = {...this.view}
    const start = performance.now()
    const tick = (now) => {
      const t = Math.min(1, (now - start) / EASE_MS)
      const k = 1 - Math.pow(1 - t, 3)
      this.setView(from.h0 + (target.h0 - from.h0) * k, from.h1 + (target.h1 - from.h1) * k)
      if (t < 1 && this.alive) this.easeFrame = requestAnimationFrame(tick)
      else this.easeFrame = null
    }
    this.easeFrame = requestAnimationFrame(tick)
  },

  refreshView() {
    if (!this.manifest) return
    const {h0, h1} = this.view
    const level = tiles.levelFor(h1 - h0 + 1)
    if (level !== this.level) {
      this.level = level
      this.updateReadoutLevel()
    }
    const generation = (this.viewGeneration = (this.viewGeneration || 0) + 1)
    const wanted = tiles.tilesFor(h0, h1, level)
    const missing = wanted.filter((idx) => !this.tileCache.has(tiles.tileKey(level, idx)))
    this.rebuildInstances()
    if (missing.length === 0) return
    for (const idx of missing) {
      this.fetchTile(level, idx).then(() => {
        if (this.alive && generation === this.viewGeneration) this.rebuildInstances()
      })
    }
  },

  xOf(height) {
    const {h0, h1} = this.view
    const span = h1 - h0 + 1
    return ((height - h0) / span) * WIDTH - WIDTH / 2
  },

  // frac: 0..1 across the canvas width
  heightAtFraction(frac) {
    const {h0, h1} = this.view
    const span = h1 - h0 + 1
    const f = Math.min(1, Math.max(0, frac))
    return tiles.step(h0 + Math.floor(f * span), 0, this.tip)
  },

  rebuildInstances() {
    if (!this.columns || !this.manifest) {
      this.requestRender()
      return
    }
    const level = this.level
    const span = tiles.spanOf(level)
    const {h0, h1} = this.view
    const visible = h1 - h0 + 1
    const unit = WIDTH / visible // world units per block
    const colW = Math.max(unit * span * 0.82, 0.02)
    const r0 = Math.floor(h0 / span) * span

    let n = 0
    let m = 0
    this.instanceHeights.length = 0
    this.instanceBaseColors.length = 0
    this.highlightedInstance = -1

    const setBox = (mesh, i, x, w, h, d, color) => {
      this.tmpPos.set(x, 0, 0)
      this.tmpScale.set(w, Math.max(h, 0.01), Math.max(d, 0.15))
      this.tmpMatrix.compose(this.tmpPos, this.tmpQuat.identity(), this.tmpScale)
      mesh.setMatrixAt(i, this.tmpMatrix)
      mesh.setColorAt(i, color)
    }

    for (let rh = r0; rh <= h1 && n < MAX_INSTANCES; rh += span) {
      const col = this.columnAt(rh)
      const x = this.xOf(rh + span / 2)
      const h = this.columnHeight(col)
      const d = col.kind === "unloaded" || col.kind === "missing" ? 0.15 : tiles.log10Scale(col.size) * Z_SCALE
      let color
      if (col.kind === "unloaded" || col.kind === "missing") {
        // Tile not loaded, or no row: a faint placeholder, never nothing.
        color = COLORS.missing
      } else {
        color = this.tmpColor.copy(COLORS.completed).lerp(COLORS.gap, col.gap)
        const mh = tiles.log10Scale(col.mean) * this.yScale
        if (mh > 0.01 && m < MAX_INSTANCES) {
          setBox(this.means, m, x, colW * 0.3, mh + 0.03, d * 0.4 + 0.1, COLORS.mean)
          m++
        }
      }
      setBox(this.columns, n, x, colW, h, d, color)
      this.instanceHeights.push(rh)
      this.instanceBaseColors.push(color.clone())
      n++
    }

    this.columns.count = n
    this.columns.instanceMatrix.needsUpdate = true
    if (this.columns.instanceColor) this.columns.instanceColor.needsUpdate = true
    this.columns.computeBoundingSphere()

    this.means.count = m
    this.means.instanceMatrix.needsUpdate = true
    if (this.means.instanceColor) this.means.instanceColor.needsUpdate = true

    this.rebuildMarkers()
    this.updateHighlight()
    this.requestRender()
  },

  // The column drawn for the record starting at `rh` at the current level.
  columnAt(rh) {
    const level = this.level
    const inBucket = Math.min(tiles.spanOf(level), this.tip - rh + 1)
    return tiles.columnFor(this.recordAt(rh, level), level, inBucket)
  },

  columnHeight(col) {
    if (col.kind === "unloaded") return GAP_HEIGHT * 0.6
    if (col.kind === "missing") return GAP_HEIGHT
    const h = tiles.log10Scale(col.tx) * this.yScale
    return col.gap > 0 ? Math.max(h, GAP_HEIGHT) : Math.max(h, 0.01)
  },

  instanceFor(height) {
    const span = tiles.spanOf(this.level)
    if (this.instanceHeights.length === 0) return -1
    const first = this.instanceHeights[0]
    const i = Math.floor((height - first) / span)
    return i >= 0 && i < this.instanceHeights.length ? i : -1
  },

  updateHighlight() {
    if (!this.columns) return
    const prev = this.highlightedInstance
    if (prev >= 0 && prev < this.columns.count) {
      this.columns.setColorAt(prev, this.instanceBaseColors[prev])
    }
    const i = this.instanceFor(this.height)
    if (i >= 0) {
      this.columns.setColorAt(i, COLORS.current)
      this.highlightedInstance = i
    } else {
      this.highlightedInstance = -1
    }
    if (this.columns.instanceColor) this.columns.instanceColor.needsUpdate = true

    const {h0, h1} = this.view
    if (this.height >= h0 && this.height <= h1 && this.yMax) {
      const unit = WIDTH / (h1 - h0 + 1)
      const w = Math.max(unit, WIDTH / 600)
      this.cursor.position.set(this.xOf(this.height + 0.5), 0, 0)
      this.cursor.scale.set(w, this.yMax * 1.05, 0.3)
      this.cursor.visible = true
    } else {
      this.cursor.visible = false
    }
    this.requestRender()
  },

  // ---------------------------------------------------------------- annotations

  setAnnotations(items) {
    this.annotations = items
      .filter((a) => a && Number.isFinite(a.height))
      .map((a) => ({...a, kind: markerKind(a.kind)}))
    for (const kind of MARKER_KINDS) {
      const needed = Math.max(1, this.annotations.filter((a) => a.kind === kind).length)
      const old = this.markers[kind]
      if (old.instanceMatrix.count < needed) {
        const fresh = new THREE.InstancedMesh(old.geometry, old.material, needed)
        fresh.frustumCulled = false
        this.scene.remove(old)
        old.dispose()
        this.scene.add(fresh)
        this.markers[kind] = fresh
      }
    }
    this.rebuildMarkers()
    this.requestRender()
  },

  rebuildMarkers() {
    if (!this.markers) return
    const {h0, h1} = this.view
    const span = tiles.spanOf(this.level)
    const unit = WIDTH / (h1 - h0 + 1)
    const size = Math.min(Math.max(unit * span * 0.6, 0.5), 1.4)
    const counts = {reorg: 0, loss: 0, burn: 0, event: 0}
    this.markerRefs = {reorg: [], loss: [], burn: [], event: []}
    for (const a of this.annotations) {
      if (a.height < h0 || a.height > h1) continue
      const mesh = this.markers[a.kind]
      const i = counts[a.kind]
      if (i >= mesh.instanceMatrix.count) continue
      const col = this.columnAt(Math.floor(a.height / span) * span)
      const top = col.kind === "unloaded" ? (this.yMax ? this.yMax * 0.5 : 6) : this.columnHeight(col)
      this.tmpPos.set(this.xOf(a.height + 0.5), top + size * 1.6, 0)
      this.tmpScale.set(size, size * 1.4, size)
      this.tmpMatrix.compose(this.tmpPos, this.tmpQuat.identity(), this.tmpScale)
      mesh.setMatrixAt(i, this.tmpMatrix)
      if (a.kind === "event") mesh.setColorAt(i, EVENT_COLORS[a.event_kind] || EVENT_COLORS.note)
      this.markerRefs[a.kind][i] = a
      counts[a.kind]++
    }
    for (const kind of MARKER_KINDS) {
      const mesh = this.markers[kind]
      mesh.count = counts[kind]
      mesh.instanceMatrix.needsUpdate = true
      if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true
      if (mesh.count > 0) mesh.computeBoundingSphere()
    }
  },

  pickMarker(clientX, clientY) {
    const rect = this.els.canvas.getBoundingClientRect()
    this.pointerNdc.set(((clientX - rect.left) / rect.width) * 2 - 1, -((clientY - rect.top) / rect.height) * 2 + 1)
    this.raycaster.setFromCamera(this.pointerNdc, this.camera)
    for (const kind of MARKER_KINDS) {
      const mesh = this.markers[kind]
      if (mesh.count === 0) continue
      const hits = this.raycaster.intersectObject(mesh, false)
      if (hits.length && hits[0].instanceId != null) {
        const a = this.markerRefs[kind][hits[0].instanceId]
        if (a) return a
      }
    }
    return null
  },

  // ---------------------------------------------------------------- controls

  on(el, type, fn, opts) {
    if (!el) return
    el.addEventListener(type, fn, opts)
    this.boundListeners = this.boundListeners || []
    this.boundListeners.push([el, type, fn])
  },

  // A hovered diamond says what it is; a click opens its evidence.
  showMarkerTip(e) {
    const tip = this.els.markerTip
    if (!tip || this.drag) return
    const marker = this.pickMarker(e.clientX, e.clientY)
    if (!marker) {
      if (tip.innerHTML) tip.innerHTML = ""
      this.els.canvas.style.cursor = ""
      return
    }
    const kind = marker.kind === "event" ? marker.event_kind || "event" : marker.kind
    const detail = marker.detail ? String(marker.detail) : ""
    tip.innerHTML =
      `<div class="font-medium text-gray-900 dark:text-white">${escapeHtml(marker.label)}</div>` +
      `<div>${escapeHtml(kind)} · block ${fmtInt(marker.height)}</div>` +
      (detail ? `<div>${escapeHtml(detail.length > 180 ? detail.slice(0, 177) + "…" : detail)}</div>` : "") +
      (marker.evidence_url ? `<div class="text-gray-600 dark:text-gray-400">Click to open the evidence</div>` : "")
    const rect = this.els.canvas.getBoundingClientRect()
    tip.style.left = `${Math.min(e.clientX - rect.left + 14, rect.width - 280)}px`
    tip.style.top = `${e.clientY - rect.top + 14}px`
    this.els.canvas.style.cursor = "pointer"
  },

  bindControls() {
    const canvas = this.els.canvas
    this.on(canvas, "pointermove", (e) => this.showMarkerTip(e))
    this.on(canvas, "pointerleave", () => {
      if (this.els.markerTip) this.els.markerTip.innerHTML = ""
    })

    this.onWheel = (e) => {
      if (!this.manifest) return
      e.preventDefault()
      const rect = canvas.getBoundingClientRect()
      const px = e.clientX - rect.left
      const frac = Math.min(1, Math.max(0, px / Math.max(1, rect.width)))
      const {h0, h1} = this.view
      const span = h1 - h0 + 1
      const cursorH = h0 + frac * span
      const factor = Math.exp((e.deltaMode === 1 ? e.deltaY * 16 : e.deltaY) * 0.0015)
      const newSpan = Math.max(MIN_SPAN, Math.min(this.tip + 1, span * factor))
      const nh0 = cursorH - frac * newSpan
      this.setView(nh0, nh0 + newSpan - 1)
    }
    canvas.addEventListener("wheel", this.onWheel, {passive: false})

    this.drag = null
    this.onPointerDown = (e) => {
      if (e.button !== undefined && e.button !== 0) return
      this.drag = {x: e.clientX, y: e.clientY, h0: this.view.h0, h1: this.view.h1, moved: false, id: e.pointerId}
      canvas.style.cursor = "grabbing"
      if (canvas.setPointerCapture && e.pointerId != null) {
        try {
          canvas.setPointerCapture(e.pointerId)
        } catch (_) {
          // ignore
        }
      }
    }
    this.onPointerMove = (e) => {
      if (!this.drag) return
      const dx = e.clientX - this.drag.x
      if (!this.drag.moved && Math.abs(dx) < DRAG_PX && Math.abs(e.clientY - this.drag.y) < DRAG_PX) return
      this.drag.moved = true
      const rect = canvas.getBoundingClientRect()
      const span = this.drag.h1 - this.drag.h0 + 1
      const dh = (-dx / Math.max(1, rect.width)) * span
      this.setView(this.drag.h0 + dh, this.drag.h0 + dh + span - 1)
    }
    this.onPointerUp = (e) => {
      if (!this.drag) return
      const wasDrag = this.drag.moved
      this.drag = null
      canvas.style.cursor = ""
      if (wasDrag) return
      const marker = this.pickMarker(e.clientX, e.clientY)
      if (marker && marker.evidence_url) {
        window.open(marker.evidence_url, "_blank", "noopener")
        return
      }
      if (!this.manifest) return
      const rect = canvas.getBoundingClientRect()
      this.setHeight(this.heightAtFraction((e.clientX - rect.left) / Math.max(1, rect.width)))
    }
    canvas.addEventListener("pointerdown", this.onPointerDown)
    window.addEventListener("pointermove", this.onPointerMove)
    window.addEventListener("pointerup", this.onPointerUp)

    this.onKeyDown = (e) => {
      if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey) return
      if (isTextInput(e.target)) return
      const delta = tiles.keyDelta(e.key, e.shiftKey)
      if (delta === null) return
      e.preventDefault()
      if (delta === "home") this.setHeight(0)
      else if (delta === "end") this.setHeight(this.tip)
      else this.setHeight(tiles.step(this.height, delta, this.tip))
    }
    window.addEventListener("keydown", this.onKeyDown)

    this.on(this.els.range, "input", (e) => {
      const h = parseInt(e.target.value, 10)
      if (Number.isFinite(h)) this.setHeight(h, {fromRange: true})
    })

    for (const btn of this.el.querySelectorAll("[data-scrubber-action]")) {
      this.on(btn, "click", (e) => {
        e.preventDefault()
        switch (btn.dataset.scrubberAction) {
          case "step-back":
            this.setHeight(tiles.step(this.height, -1, this.tip))
            break
          case "step-forward":
            this.setHeight(tiles.step(this.height, 1, this.tip))
            break
          case "play":
            this.startPlay()
            break
          case "pause":
            this.stopPlay()
            break
          case "home":
            this.setHeight(0)
            break
          case "end":
            this.setHeight(this.tip)
            break
          default:
            break
        }
      })
    }
  },

  // ---------------------------------------------------------------- scrubber

  setHeight(h, opts = {}) {
    const next = tiles.step(h, 0, this.tip)
    const changed = next !== this.height
    this.height = next
    if (!opts.fromRange) this.updateRange()

    const {h0, h1} = this.view
    if (next < h0 || next > h1) {
      const span = h1 - h0 + 1
      const nh0 = next - Math.floor(span / 2)
      this.easeViewTo(nh0, nh0 + span - 1)
    }
    this.updateHighlight()
    this.updateReadout()

    if (!this.manifest) return
    const leafIdx = tiles.tileIndex(next, 0)
    if (!this.tileCache.has(tiles.tileKey(0, leafIdx))) {
      this.fetchTile(0, leafIdx).then(() => {
        if (this.alive && this.height === next) this.updateReadout()
      })
    }
    if (changed || this.lastRestHeight !== next) this.scheduleRest()
  },

  scheduleRest() {
    if (this.restTimer) clearTimeout(this.restTimer)
    this.restTimer = setTimeout(() => {
      this.restTimer = null
      if (!this.alive) return
      if (this.lastRestHeight === this.height) return
      this.lastRestHeight = this.height
      this.pushEvent("rest", {height: this.height})
    }, REST_MS)
  },

  startPlay() {
    if (this.reducedMotion) {
      this.statusNote = "Play is off under reduced motion."
      this.updateStatus()
      return
    }
    if (this.playTimer) return
    this.statusNote = "Playing: one block every 250 ms."
    this.updateStatus()
    this.playTimer = setInterval(() => {
      if (!this.alive) return this.stopPlay()
      if (this.height >= this.tip) return this.stopPlay()
      this.setHeight(tiles.step(this.height, 1, this.tip))
    }, PLAY_MS)
  },

  stopPlay() {
    if (this.playTimer) {
      clearInterval(this.playTimer)
      this.playTimer = null
      if (this.alive && this.statusNote.startsWith("Playing")) {
        this.statusNote = ""
        this.updateStatus()
      }
    }
  },

  // ---------------------------------------------------------------- readout

  setText(key, text) {
    const el = this.els.readout[key]
    if (el) el.textContent = text
  },

  setStatus(note) {
    this.statusNote = note || ""
    this.updateStatus()
  },

  updateStatus() {
    const parts = [
      `Column height = log10(tx + 1), axis top 10^${this.decades} tx; depth = log10(bytes + 1): log10 scale.`
    ]
    if (this.statusNote) parts.unshift(this.statusNote)
    if (this.loadingTiles > 0) parts.push(`Loading ${this.loadingTiles} tile${this.loadingTiles === 1 ? "" : "s"}…`)
    this.setText("status", parts.join(" "))
  },

  updateReadoutLevel() {
    const span = tiles.spanOf(this.level)
    this.setText(
      "level",
      this.level === 0
        ? "1 block per column"
        : `1 column per ${fmtInt(span)} blocks (largest block drawn; red = share of blocks not completed)`
    )
  },

  updateReadout() {
    this.setText("height", `#${fmtInt(this.height)}`)
    const rec = this.recordAt(this.height, 0)
    if (!rec) {
      this.setText("time", "…")
      this.setText("size", "…")
      this.setText("num_tx", "…")
      this.setText("state", this.manifest ? "…" : "")
      return
    }
    this.setText("time", fmtTime(rec.time))
    this.setText("size", rec.state === 0 ? "—" : fmtBytes(rec.size))
    this.setText("num_tx", rec.state === 0 ? "—" : `${fmtInt(rec.numTx)} tx`)
    const name = tiles.stateName(rec.state)
    this.setText("state", tiles.isGap(rec.state) ? `${name} (gap)` : name)
  },

  updateRangeBounds() {
    const r = this.els.range
    if (r) r.max = String(this.tip)
  },

  updateRange() {
    const r = this.els.range
    if (!r) return
    if (String(r.max) !== String(this.tip)) r.max = String(this.tip)
    if (parseInt(r.value, 10) !== this.height) r.value = String(this.height)
  },

  // ---------------------------------------------------------------- detail

  renderDetail(payload) {
    const el = this.els.detail
    if (!el || !payload) return
    switch (payload.kind) {
      case "gap":
        el.innerHTML = this.gapHtml(payload)
        break
      case "marks":
        el.innerHTML = this.marksHtml(payload)
        break
      case "density":
        el.innerHTML = this.densityHtml(payload)
        this.drawDensity(payload)
        break
      case "unavailable":
        el.innerHTML = `<p
  class="text-sm text-gray-600 dark:text-gray-400"
>Transaction sample unavailable (${escapeHtml(payload.reason || "no reason given")}).</p>`
        break
      default:
        el.innerHTML = `<p
  class="text-sm text-gray-600 dark:text-gray-400"
>Unknown detail kind ${escapeHtml(payload.kind)}.</p>`
    }
  },

  gapHtml(p) {
    return `<p
  class="text-sm text-red-700 dark:text-red-300"
>Block ${fmtInt(p.height)} is not completed (${escapeHtml(p.state || "unknown")}).
Its transactions are not indexed yet.</p>`
  },

  marksHtml(p) {
    const txs = Array.isArray(p.txs) ? p.txs : []
    const sample = Number.isFinite(p.sample) ? p.sample : txs.length
    const total = Number.isFinite(p.num_tx) ? p.num_tx : sample
    const squares = txs
      .map((tx) => {
        const protocols = Array.isArray(tx.protocols) ? tx.protocols : []
        const cls = tx.coinbase ? "coinbase" : protocols.length ? "protocol" : "plain"
        const px = Math.round(4 + 1.6 * tiles.log10Scale(Number(tx.sats) || 0))
        const title = [
          tx.txid,
          fmtSats(Number(tx.sats)),
          `${fmtInt(tx.inputs)} in / ${fmtInt(tx.outputs)} out`,
          tx.coinbase ? "coinbase" : protocols.length ? protocols.join(", ") : "plain transfer"
        ].join(" · ")
        return `<a
  href="/transactions/${encodeURIComponent(tx.txid)}"
  title="${escapeHtml(title)}"
  class="inline-block rounded-sm"
  style="width:${px}px;height:${px}px;background:${MARK_COLORS[cls]}"
></a>`
      })
      .join("")
    const header =
      sample < total
        ? `Showing sample of ${fmtInt(sample)} of ${fmtInt(total)} transactions in block ${fmtInt(p.height)}.`
        : `All ${fmtInt(total)} transactions in block ${fmtInt(p.height)}.`
    return `<p
  class="text-sm text-gray-700 dark:text-gray-300"
>${header}
One square per transaction, sized by log10(satoshis + 1); gold = coinbase, green = protocol, grey = plain transfer.</p>
<div
  class="flex flex-wrap items-end gap-px"
>${squares}</div>`
  },

  densityHtml(p) {
    const rows = Array.isArray(p.rows) ? p.rows : []
    const cols = Number.isFinite(p.cols) ? p.cols : 64
    const sample = Number.isFinite(p.sample) ? p.sample : 0
    const total = Number.isFinite(p.num_tx) ? p.num_tx : sample
    const rowH = 12
    const labelW = 128
    const cellW = Math.floor((640 - labelW) / cols)
    const w = labelW + cellW * cols
    const h = Math.max(rowH, rows.length * rowH)
    return `<p
  class="text-sm text-gray-700 dark:text-gray-300"
>Block ${fmtInt(p.height)} has ${fmtInt(total)} transactions; density from a sample of ${fmtInt(sample)} of ${fmtInt(total)} txs.
Rows: tx class by protocol (coinbase, plain transfer, protocol); columns: log2 of output value in satoshis, bins 0..${cols - 1}.
The grid is a fixed ${rows.length} × ${cols}; its size does not depend on the block's tx count.</p>
<canvas
  id="chain-scrubber-density"
  width="${w}"
  height="${h}"
  style="width:${w}px;height:${h}px"
  aria-label="Transaction density heat grid"
></canvas>`
  },

  drawDensity(p) {
    const canvas = this.els.detail && this.els.detail.querySelector("#chain-scrubber-density")
    if (!canvas) return
    const ctx = canvas.getContext("2d")
    if (!ctx) return
    const rows = Array.isArray(p.rows) ? p.rows : []
    const cols = Number.isFinite(p.cols) ? p.cols : 64
    const grid = Array.isArray(p.grid) ? p.grid : []
    const rowH = 12
    const labelW = 128
    const cellW = Math.floor((640 - labelW) / cols)
    let max = 0
    for (const v of grid) if (v > max) max = v
    const logMax = Math.log10(max + 1) || 1

    ctx.fillStyle = "#0b1120"
    ctx.fillRect(0, 0, canvas.width, canvas.height)
    ctx.font = "10px ui-monospace, SFMono-Regular, Menlo, monospace"
    ctx.textBaseline = "middle"
    rows.forEach((name, r) => {
      ctx.fillStyle = "#cbd5e1"
      ctx.fillText(String(name).slice(0, 18), 4, r * rowH + rowH / 2)
      for (let c = 0; c < cols; c++) {
        const v = grid[r * cols + c] || 0
        const t = v > 0 ? Math.log10(v + 1) / logMax : 0
        if (t === 0) {
          ctx.fillStyle = "#111827"
        } else {
          // blue → amber ramp on a dark ground
          const red = Math.round(40 + 205 * t)
          const green = Math.round(90 + 90 * t)
          const blue = Math.round(220 - 200 * t)
          ctx.fillStyle = `rgb(${red},${green},${blue})`
        }
        ctx.fillRect(labelW + c * cellW, r * rowH, cellW - 1, rowH - 1)
      }
    })
  }
}
