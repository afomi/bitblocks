// TxFlow — the transaction graph as a space you can fly through and scrub.
// Every tx in the loaded range is a point on its block's sunflower disc along
// the height spine; every output an ember beside it; every input an arc from
// the output it spends. Layout is fixed by the data (../tx_flow/layout.mjs),
// so scrubbing never moves a node: the playhead and range are shader
// uniforms, and moving them costs no CPU work and no refetch.
//
// At playhead H: txs mined by H are lit and later ones are ghosts; an output
// created by H and not yet spent glows gold (the live UTXO set), a spent one
// fades to ash; an arc appears in the block that spent it, flashes, then
// settles. Reduced motion turns off the shimmer, the flash and camera easing.

import * as THREE from "three"
import {OrbitControls} from "three/examples/jsm/controls/OrbitControls.js"
import * as layout from "../tx_flow/layout.mjs"

const BACKGROUND = 0x050608 // keep equal to #tx-flow-canvas bg-[#050608]
const PLAY_SECONDS = 40 // the whole range plays in this long
const EVENT_COLORS = {
  fork: "#a78bfa",
  upgrade: "#38bdf8",
  halving: "#fbbf24",
  milestone: "#34d399",
  mint: "#f472b6",
  world: "#e5e7eb",
  note: "#60a5fa"
}

const POINT_VERT = `
  attribute float aBorn;
  attribute float aSpent;
  attribute float aSize;
  attribute float aKind;   // 0 tx, 1 coinbase tx, 2 output
  attribute float aSel;
  uniform float uPlay;
  uniform float uScale;
  varying vec4 vColor;
  void main() {
    vec4 mv = modelViewMatrix * vec4(position, 1.0);
    gl_Position = projectionMatrix * mv;
    float born = step(aBorn, uPlay);
    float spent = step(aSpent, uPlay);
    vec3 tx = vec3(0.62, 0.80, 1.0);
    vec3 coinbase = vec3(1.0, 0.72, 0.30);
    vec3 alive = vec3(1.0, 0.80, 0.28);
    vec3 ash = vec3(0.33, 0.38, 0.47);
    vec3 c;
    float a;
    if (aKind < 1.5) {
      c = aKind > 0.5 ? coinbase : tx;
      a = mix(0.07, 0.95, born);
    } else {
      c = mix(alive, ash, spent);
      a = born * mix(0.85, 0.22, spent) + (1.0 - born) * 0.035;
    }
    float now = born * (1.0 - step(aBorn + 0.5, uPlay));
    c = mix(c, vec3(1.0), 0.6 * now);
    c = mix(c, vec3(0.40, 0.95, 1.0), aSel);
    a = max(a, aSel);
    vColor = vec4(c, a);
    float size = aSize * (aKind > 1.5 ? 0.7 : 1.0) * (1.0 + 0.8 * now + 0.6 * aSel);
    gl_PointSize = clamp(size * uScale / -mv.z, 1.5, 48.0);
  }
`

const POINT_FRAG = `
  varying vec4 vColor;
  void main() {
    vec2 p = gl_PointCoord - 0.5;
    float d = length(p);
    if (d > 0.5) discard;
    float core = smoothstep(0.5, 0.0, d);
    gl_FragColor = vec4(vColor.rgb, vColor.a * core * core);
  }
`

const EDGE_VERT = `
  attribute float aBorn;
  attribute float aAlong;
  attribute float aSel;
  uniform float uPlay;
  uniform float uTime;
  uniform float uMotion;
  varying vec4 vColor;
  void main() {
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    float born = step(aBorn, uPlay);
    float age = max(0.0, uPlay - aBorn);
    float flash = born * exp(-age * 0.35) * uMotion;
    float shimmer = uMotion * born * 0.35 * (0.5 + 0.5 * sin((aAlong - uTime * 0.35) * 18.0));
    vec3 c = mix(vec3(1.0, 0.62, 0.20), vec3(1.0, 0.95, 0.85), aAlong);
    c = mix(c, vec3(0.40, 0.95, 1.0), aSel);
    float a = born * (0.38 + shimmer + 0.6 * flash) + (1.0 - born) * 0.025;
    vColor = vec4(c, max(a, aSel * 0.95));
  }
`

const EDGE_FRAG = `
  varying vec4 vColor;
  void main() { gl_FragColor = vColor; }
`

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

function fmtTime(t) {
  if (!Number.isFinite(t) || t <= 0) return "—"
  return new Date(t * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC"
}

function isTextInput(el) {
  return el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable) && el.type !== "range"
}

export default {
  mounted() {
    this.els = {
      canvas: this.el.querySelector("[data-flow-canvas]"),
      minimap: document.getElementById("tx-flow-minimap"),
      slider: document.getElementById("tx-flow-play"),
      playBtn: document.getElementById("tx-flow-playpause"),
      readout: document.getElementById("tx-flow-readout"),
      status: document.getElementById("tx-flow-status"),
      tooltip: document.getElementById("tx-flow-tooltip"),
      detail: document.getElementById("tx-flow-detail"),
      labels: document.getElementById("tx-flow-labels"),
      follow: document.getElementById("tx-flow-follow")
    }
    this.from = parseInt(this.el.dataset.from, 10)
    this.to = parseInt(this.el.dataset.to, 10)
    this.focusTxid = this.el.dataset.txid || ""
    const media = typeof window.matchMedia === "function" ? window.matchMedia("(prefers-reduced-motion: reduce)") : null
    this.reducedMotion = !!(media && media.matches)
    this.annotations = []
    this.selected = -1
    this.playing = false
    this.clock = new THREE.Clock()

    this.handleEvent("annotations", ({items}) => {
      this.annotations = (items || []).filter((a) => Number.isFinite(a.height))
      this.buildLabels()
      this.drawMinimap()
    })

    try {
      this.initScene()
    } catch (e) {
      this.setStatus("This view needs WebGL, and this browser has none.")
      return
    }
    this.bindControls()
    this.load()
  },

  destroyed() {
    this.disposed = true
    cancelAnimationFrame(this.frame)
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener("keydown", this.onKeyDown)
    if (this.controls) this.controls.dispose()
    this.clearGraph()
    if (this.renderer) this.renderer.dispose()
  },

  // ---------------------------------------------------------------- scene

  initScene() {
    const canvas = this.els.canvas
    this.renderer = new THREE.WebGLRenderer({canvas, antialias: true, powerPreference: "high-performance"})
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
    this.renderer.setClearColor(BACKGROUND, 1)
    this.scene = new THREE.Scene()
    this.scene.fog = new THREE.FogExp2(BACKGROUND, 0.0016)
    this.camera = new THREE.PerspectiveCamera(50, 1, 0.1, 6000)
    this.controls = new OrbitControls(this.camera, canvas)
    this.controls.enableDamping = !this.reducedMotion
    this.controls.dampingFactor = 0.08
    this.controls.addEventListener("change", () => (this.dirty = true))

    this.uniforms = {
      uPlay: {value: this.from},
      uTime: {value: 0},
      uScale: {value: 300},
      uMotion: {value: this.reducedMotion ? 0 : 1}
    }

    this.raycaster = new THREE.Raycaster()
    this.pointer = new THREE.Vector2()

    this.onResize = () => this.resize()
    window.addEventListener("resize", this.onResize)
    this.resize()
    this.loop()
  },

  resize() {
    const rect = this.els.canvas.parentElement.getBoundingClientRect()
    const w = Math.max(1, rect.width)
    const h = Math.max(1, rect.height)
    this.renderer.setSize(w, h, false)
    this.camera.aspect = w / h
    this.camera.updateProjectionMatrix()
    this.uniforms.uScale.value = h * 0.9
    this.dirty = true
    this.drawMinimap()
  },

  loop() {
    if (this.disposed) return
    this.frame = requestAnimationFrame(() => this.loop())
    const dt = this.clock.getDelta()
    this.uniforms.uTime.value += dt
    if (this.playing && this.flow) {
      const span = this.to - this.from + 1
      const next = this.play + Math.max(1, span / PLAY_SECONDS) * dt
      if (next >= this.to) {
        this.setPlay(this.to)
        this.setPlaying(false)
      } else {
        this.setPlay(next, {fromLoop: true})
      }
    }
    if (this.easeTarget) {
      const t = this.controls.target
      const dx = this.easeTarget.x - t.x
      if (Math.abs(dx) < 0.01) {
        this.easeTarget = null
      } else {
        const step = this.reducedMotion ? dx : dx * Math.min(1, dt * 6)
        t.x += step
        this.camera.position.x += step
      }
      this.dirty = true
    }
    const animating = !this.reducedMotion && this.flow && this.flow.edges.length > 0
    if (this.controls.enableDamping) this.controls.update()
    if (this.dirty || animating || this.playing) {
      this.renderer.render(this.scene, this.camera)
      this.placeLabels()
      this.dirty = false
    }
  },

  // ---------------------------------------------------------------- data

  async load() {
    this.setStatus(`Loading blocks ${fmtInt(this.from)} to ${fmtInt(this.to)}…`)
    let payload
    try {
      const res = await fetch(`/chain-scrubber/flow?from=${this.from}&to=${this.to}`, {
        credentials: "same-origin",
        headers: {accept: "application/json"}
      })
      payload = await res.json()
      if (!res.ok) throw new Error(payload.error || `HTTP ${res.status}`)
    } catch (e) {
      this.setStatus(`Couldn't load the range: ${e.message}.`)
      return
    }
    if (this.disposed) return
    this.flow = layout.decode(payload)
    this.to = this.flow.to
    this.stats = layout.prepareStats(this.flow)
    this.buildGraph()
    this.frameRange()

    const first = layout.firstSpend(this.flow)
    const focus = this.focusTxid ? this.flow.txIndex.get(this.focusTxid) : undefined
    if (focus !== undefined) {
      this.select(focus)
      this.setPlay(this.flow.txHeight[focus])
    } else {
      this.setPlay(this.from)
    }
    const stored = this.flow.blocks.reduce((s, b) => s + b[3], 0)
    const expected = this.flow.blocks.reduce((s, b) => s + b[2], 0)
    const parts = [
      `${fmtInt(this.flow.n)} txs, ${fmtInt(this.flow.edges.length)} spends, ${fmtInt(this.flow.outCount)} outputs in blocks ${fmtInt(this.from)} to ${fmtInt(this.to)}.`
    ]
    if (stored < expected) parts.push(`${fmtInt(expected - stored)} txs in this range aren't synced yet.`)
    if (this.flow.truncated) parts.push(`Cut at block ${fmtInt(this.to)} to stay under the tx cap.`)
    if (first) parts.push(`First spend here: block ${fmtInt(first.height)}.`)
    if (Number.isFinite(this.flow.spendsKnownThrough)) {
      parts.push(`Spends are known through block ${fmtInt(this.flow.spendsKnownThrough)}.`)
    }
    this.setStatus(parts.join(" "))
    this.drawMinimap()
    this.buildLabels()
  },

  clearGraph() {
    for (const key of ["points", "outPoints", "edgeLines", "spine", "playRing"]) {
      const obj = this[key]
      if (!obj) continue
      this.scene.remove(obj)
      obj.geometry.dispose()
      obj.material.dispose()
      this[key] = null
    }
  },

  buildGraph() {
    this.clearGraph()
    const f = this.flow

    // Tx cores.
    const g = new THREE.BufferGeometry()
    g.setAttribute("position", new THREE.BufferAttribute(f.txPos, 3))
    g.setAttribute("aBorn", new THREE.BufferAttribute(f.txHeight, 1))
    g.setAttribute("aSpent", new THREE.BufferAttribute(new Float32Array(f.n).fill(layout.NEVER), 1))
    g.setAttribute("aSize", new THREE.BufferAttribute(f.txSize.map((s) => s * 9), 1))
    g.setAttribute("aKind", new THREE.BufferAttribute(Float32Array.from(f.txCoinbase), 1))
    this.txSel = new THREE.BufferAttribute(new Float32Array(f.n), 1)
    g.setAttribute("aSel", this.txSel)
    this.points = new THREE.Points(g, this.pointMaterial())
    this.points.frustumCulled = false
    this.scene.add(this.points)

    // Outputs.
    const og = new THREE.BufferGeometry()
    og.setAttribute("position", new THREE.BufferAttribute(f.outPos, 3))
    og.setAttribute("aBorn", new THREE.BufferAttribute(f.outBorn, 1))
    og.setAttribute("aSpent", new THREE.BufferAttribute(f.outSpent, 1))
    og.setAttribute(
      "aSize",
      new THREE.BufferAttribute(Float32Array.from(f.outSats, (s) => layout.sizeFor(s) * 7), 1)
    )
    og.setAttribute("aKind", new THREE.BufferAttribute(new Float32Array(f.outCount).fill(2), 1))
    og.setAttribute("aSel", new THREE.BufferAttribute(new Float32Array(f.outCount), 1))
    this.outPoints = new THREE.Points(og, this.pointMaterial())
    this.outPoints.frustumCulled = false
    this.scene.add(this.outPoints)

    // Arcs.
    const e = layout.edgeGeometry(f)
    this.edgeOf = e.edgeOf
    const eg = new THREE.BufferGeometry()
    eg.setAttribute("position", new THREE.BufferAttribute(e.pos, 3))
    eg.setAttribute("aBorn", new THREE.BufferAttribute(e.born, 1))
    eg.setAttribute("aAlong", new THREE.BufferAttribute(e.along, 1))
    this.edgeSel = new THREE.BufferAttribute(new Float32Array(e.count), 1)
    eg.setAttribute("aSel", this.edgeSel)
    this.edgeLines = new THREE.LineSegments(
      eg,
      new THREE.ShaderMaterial({
        uniforms: this.uniforms,
        vertexShader: EDGE_VERT,
        fragmentShader: EDGE_FRAG,
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending
      })
    )
    this.edgeLines.frustumCulled = false
    this.scene.add(this.edgeLines)

    // The spine and the playhead ring.
    const length = (this.to - this.from) * f.gap
    const sg = new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(0, 0, 0), new THREE.Vector3(length, 0, 0)])
    this.spine = new THREE.Line(sg, new THREE.LineBasicMaterial({color: 0x334155, transparent: true, opacity: 0.8}))
    this.scene.add(this.spine)

    let maxDisc = 0
    for (const b of f.blocks) maxDisc = Math.max(maxDisc, layout.discRadius(b[3] || 1, f.gap))
    const ring = new THREE.RingGeometry(maxDisc + f.gap * 0.6, maxDisc + f.gap * 0.75, 96)
    ring.rotateY(Math.PI / 2)
    this.playRing = new THREE.Mesh(
      ring,
      new THREE.MeshBasicMaterial({color: 0xf59e0b, transparent: true, opacity: 0.55, side: THREE.DoubleSide, depthWrite: false})
    )
    this.scene.add(this.playRing)
    this.dirty = true
  },

  pointMaterial() {
    return new THREE.ShaderMaterial({
      uniforms: this.uniforms,
      vertexShader: POINT_VERT,
      fragmentShader: POINT_FRAG,
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending
    })
  },

  frameRange() {
    const f = this.flow
    const length = Math.max(1, (this.to - this.from) * f.gap)
    const mid = length / 2
    this.controls.target.set(mid, 0, 0)
    this.camera.position.set(mid - length * 0.35, length * 0.28, length * 0.62)
    this.camera.near = Math.max(0.05, length / 20000)
    this.camera.far = length * 20
    this.camera.updateProjectionMatrix()
    this.scene.fog.density = 1.1 / (length * 1.6)
    this.controls.update()
    this.dirty = true
  },

  // ---------------------------------------------------------------- playhead

  setPlay(h, opts = {}) {
    if (!this.flow) return
    const play = Math.min(this.to, Math.max(this.from, h))
    this.play = play
    this.uniforms.uPlay.value = Math.floor(play)
    const x = (Math.floor(play) - this.from) * this.flow.gap
    if (this.playRing) this.playRing.position.x = x
    if (this.els.slider && !opts.fromSlider) this.els.slider.value = String(Math.floor(play))
    if (this.els.follow && this.els.follow.checked && (opts.fromLoop || opts.fromSlider || opts.fromKey)) {
      this.easeTarget = {x}
    }
    this.renderReadout()
    this.drawMinimap()
    this.dirty = true
  },

  setPlaying(on) {
    this.playing = on && !!this.flow
    if (this.playing && this.play >= this.to) this.setPlay(this.from)
    if (this.els.playBtn) {
      this.els.playBtn.textContent = this.playing ? "Pause" : "Play"
      this.els.playBtn.setAttribute("aria-pressed", this.playing ? "true" : "false")
    }
  },

  renderReadout() {
    if (!this.els.readout || !this.flow) return
    const h = Math.floor(this.play)
    const block = this.flow.blocks.find((b) => b[0] === h)
    const s = layout.statsAt(this.stats, h)
    const here = this.annotations.filter((a) => a.height === h)
    this.els.readout.innerHTML =
      `<span class="font-semibold text-gray-900 dark:text-white">Block ${fmtInt(h)}</span>` +
      ` <span>${escapeHtml(fmtTime(block && block[1]))}</span>` +
      ` <span>· ${fmtInt(s.txs)} txs mined</span>` +
      ` <span>· ${fmtInt(s.spends)} spends</span>` +
      ` <span>· ${fmtInt(s.alive)} of ${fmtInt(s.outputs)} outputs unspent (${escapeHtml(layout.fmtCoins(s.aliveSats))} coins)</span>` +
      here
        .map(
          (a) =>
            ` <span class="font-medium text-gray-900 dark:text-white">· ${escapeHtml(a.label)}</span>`
        )
        .join("")
  },

  // ---------------------------------------------------------------- minimap

  drawMinimap() {
    const c = this.els.minimap
    if (!c || !this.flow) return
    const rect = c.getBoundingClientRect()
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    c.width = Math.max(1, Math.round(rect.width * dpr))
    c.height = Math.max(1, Math.round(rect.height * dpr))
    const ctx = c.getContext("2d")
    const w = c.width
    const h = c.height
    ctx.clearRect(0, 0, w, h)
    const span = this.to - this.from + 1
    const xOf = (height) => ((height - this.from + 0.5) / span) * w
    const dark = document.documentElement.classList.contains("dark")

    // Txs per block (log), and spends per block above them.
    const spends = new Map()
    for (const e of this.flow.edges) {
      const bh = this.flow.txHeight[e.dst]
      spends.set(bh, (spends.get(bh) || 0) + 1)
    }
    let maxTx = 1
    for (const b of this.flow.blocks) maxTx = Math.max(maxTx, b[3])
    const barW = Math.max(1, w / span)
    ctx.fillStyle = dark ? "rgba(148,163,184,0.55)" : "rgba(71,85,105,0.55)"
    for (const b of this.flow.blocks) {
      const bh = (Math.log10(1 + b[3]) / Math.log10(1 + maxTx)) * h * 0.55
      ctx.fillRect(xOf(b[0]) - barW / 2, h - bh, barW, bh)
    }
    ctx.fillStyle = dark ? "#fbbf24" : "#b45309"
    for (const [bh, n] of spends) {
      const sh = Math.min(h * 0.4, 4 * dpr + Math.log2(1 + n) * 3 * dpr)
      ctx.fillRect(xOf(bh) - Math.max(barW, 2 * dpr) / 2, 0, Math.max(barW, 2 * dpr), sh)
    }
    // Annotations.
    for (const a of this.annotations) {
      if (a.height < this.from || a.height > this.to) continue
      ctx.fillStyle = EVENT_COLORS[a.event_kind] || (dark ? "#e5e7eb" : "#374151")
      ctx.fillRect(xOf(a.height) - dpr, 0, 2 * dpr, h)
    }
    // Playhead.
    ctx.fillStyle = dark ? "#f59e0b" : "#c2410c"
    ctx.fillRect(xOf(Math.floor(this.play)) - dpr, 0, 2 * dpr, h)
  },

  // ---------------------------------------------------------------- labels

  buildLabels() {
    const box = this.els.labels
    if (!box) return
    box.innerHTML = ""
    this.labelEls = []
    if (!this.flow) return
    for (const a of this.annotations) {
      if (a.height < this.from || a.height > this.to) continue
      const el = document.createElement("a")
      el.href = a.evidence_url || "/annotations"
      el.target = "_blank"
      el.rel = "noopener noreferrer"
      el.className =
        "absolute -translate-x-1/2 -translate-y-full whitespace-nowrap rounded border border-gray-200 bg-white/95 px-1.5 py-0.5 text-[11px] text-gray-800 shadow-sm hover:border-orange-400 dark:border-gray-700 dark:bg-gray-800/95 dark:text-gray-200"
      el.style.borderLeft = `3px solid ${EVENT_COLORS[a.event_kind] || "#94a3b8"}`
      el.textContent = `${a.label} · ${a.height}`
      el.title = a.detail || a.label
      box.appendChild(el)
      this.labelEls.push({el, a})
    }
    this.dirty = true
  },

  placeLabels() {
    if (!this.labelEls || !this.flow) return
    const rect = this.els.canvas.getBoundingClientRect()
    const v = new THREE.Vector3()
    const top = layout.discRadius(1, this.flow.gap) + this.flow.gap * 3
    for (const {el, a} of this.labelEls) {
      v.set((a.height - this.from) * this.flow.gap, top, 0).project(this.camera)
      const visible = v.z < 1 && Math.abs(v.x) <= 1.05 && Math.abs(v.y) <= 1.05
      el.style.display = visible ? "" : "none"
      if (!visible) continue
      el.style.left = `${((v.x + 1) / 2) * rect.width}px`
      el.style.top = `${((1 - v.y) / 2) * rect.height}px`
      el.style.opacity = a.height <= Math.floor(this.play) ? "1" : "0.55"
    }
  },

  // ---------------------------------------------------------------- picking

  pick(clientX, clientY) {
    if (!this.points) return -1
    const rect = this.els.canvas.getBoundingClientRect()
    this.pointer.set(((clientX - rect.left) / rect.width) * 2 - 1, -((clientY - rect.top) / rect.height) * 2 + 1)
    this.raycaster.setFromCamera(this.pointer, this.camera)
    const dist = this.camera.position.distanceTo(this.controls.target)
    this.raycaster.params.Points.threshold = Math.max(this.flow.gap * 0.25, dist * 0.006)
    const hits = this.raycaster.intersectObject(this.points, false)
    return hits.length ? hits[0].index : -1
  },

  txDetail(i, withLinks) {
    const f = this.flow
    const [h, txid, cb, nIn, satsOut] = f.txs[i]
    const outs = f.outOffset[i + 1] - f.outOffset[i]
    let spent = 0
    for (let o = f.outOffset[i]; o < f.outOffset[i + 1]; o++) if (f.outSpent[o] <= this.play) spent++
    const lines = [
      `<div class="font-mono text-xs text-gray-900 dark:text-white">${escapeHtml(txid.slice(0, 16))}…</div>`,
      `<div>Block ${fmtInt(h)}${cb ? " · coinbase" : ""}</div>`,
      `<div>${cb ? "No inputs" : `${fmtInt(nIn)} inputs`} · ${fmtInt(outs)} outputs, ${fmtInt(spent)} spent by block ${fmtInt(Math.floor(this.play))}</div>`,
      `<div>${satsOut >= 0 ? `${escapeHtml(layout.fmtCoins(satsOut))} coins out` : "Value unknown"}</div>`
    ]
    if (withLinks) {
      lines.push(
        `<div class="mt-1 flex gap-3"><a class="text-blue-700 hover:text-blue-900 dark:text-blue-400 dark:hover:text-blue-300" href="/transactions/${escapeHtml(txid)}">Transaction</a>` +
          `<a class="text-blue-700 hover:text-blue-900 dark:text-blue-400 dark:hover:text-blue-300" href="/blocks/${h}">Block</a></div>`
      )
    }
    return lines.join("")
  },

  select(i) {
    const f = this.flow
    this.selected = i
    this.txSel.array.fill(0)
    this.edgeSel.array.fill(0)
    if (i >= 0) {
      const {txs, edges} = layout.lineage(f, i)
      for (const t of txs) this.txSel.array[t] = 1
      for (let v = 0; v < this.edgeOf.length; v++) if (edges.has(this.edgeOf[v])) this.edgeSel.array[v] = 1
      if (this.els.detail) {
        this.els.detail.innerHTML =
          this.txDetail(i, true) +
          `<div class="mt-1">Lineage in range: ${fmtInt(txs.size)} txs, ${fmtInt(edges.size)} spends.</div>`
      }
    } else if (this.els.detail) {
      this.els.detail.innerHTML = ""
    }
    this.txSel.needsUpdate = true
    this.edgeSel.needsUpdate = true
    this.dirty = true
  },

  // ---------------------------------------------------------------- controls

  bindControls() {
    const canvas = this.els.canvas
    let down = null
    canvas.addEventListener("pointerdown", (e) => (down = {x: e.clientX, y: e.clientY}))
    canvas.addEventListener("pointerup", (e) => {
      if (!down || !this.flow) return
      const moved = Math.abs(e.clientX - down.x) + Math.abs(e.clientY - down.y) > 4
      down = null
      if (moved) return
      this.select(this.pick(e.clientX, e.clientY))
    })
    canvas.addEventListener("pointermove", (e) => {
      if (!this.flow || !this.els.tooltip || e.buttons) return
      const i = this.pick(e.clientX, e.clientY)
      const tip = this.els.tooltip
      if (i < 0) {
        tip.innerHTML = ""
        canvas.style.cursor = ""
        return
      }
      canvas.style.cursor = "pointer"
      const rect = canvas.getBoundingClientRect()
      tip.innerHTML = this.txDetail(i, false)
      tip.style.left = `${e.clientX - rect.left + 14}px`
      tip.style.top = `${e.clientY - rect.top + 14}px`
    })
    canvas.addEventListener("pointerleave", () => this.els.tooltip && (this.els.tooltip.innerHTML = ""))

    if (this.els.slider) {
      this.els.slider.min = String(this.from)
      this.els.slider.max = String(this.to)
      this.els.slider.addEventListener("input", () =>
        this.setPlay(parseInt(this.els.slider.value, 10), {fromSlider: true})
      )
    }
    if (this.els.playBtn) this.els.playBtn.addEventListener("click", () => this.setPlaying(!this.playing))
    if (this.reducedMotion && this.els.playBtn) this.els.playBtn.title = "Steps a block at a time with reduced motion"

    const mini = this.els.minimap
    if (mini) {
      const scrub = (e) => {
        if (!this.flow) return
        const rect = mini.getBoundingClientRect()
        const frac = Math.min(1, Math.max(0, (e.clientX - rect.left) / Math.max(1, rect.width)))
        this.setPlay(this.from + Math.floor(frac * (this.to - this.from + 1)), {fromSlider: true})
      }
      mini.addEventListener("pointerdown", (e) => {
        mini.setPointerCapture(e.pointerId)
        scrub(e)
      })
      mini.addEventListener("pointermove", (e) => e.buttons && scrub(e))
    }

    this.onKeyDown = (e) => {
      if (!this.flow || e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey) return
      if (isTextInput(e.target)) return
      const step = e.shiftKey ? 10 : 1
      const key = e.key
      if (key === "ArrowRight") this.setPlay(Math.floor(this.play) + step, {fromKey: true})
      else if (key === "ArrowLeft") this.setPlay(Math.floor(this.play) - step, {fromKey: true})
      else if (key === "Home") this.setPlay(this.from, {fromKey: true})
      else if (key === "End") this.setPlay(this.to, {fromKey: true})
      else if (key === " " && e.target === document.body) this.setPlaying(!this.playing)
      else if (key === "Escape") this.select(-1)
      else if (key === "f") this.frameRange()
      else return
      e.preventDefault()
    }
    window.addEventListener("keydown", this.onKeyDown)
  },

  setStatus(text) {
    if (this.els.status) this.els.status.textContent = text
  }
}
