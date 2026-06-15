import * as THREE from "three"
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js"

const GLOBE_RADIUS = 50
const DOT_SIZE = 1.2
const ARC_SEGMENTS = 48
const COLORS = {
  globe: 0x111827,
  globeEdge: 0x2563eb,
  land: 0xe2e8f0,
  landShadow: 0x0f172a,
  grid: 0x1e3a5f,
  inbound: 0x4ade80,
  outbound: 0x60a5fa,
  arc: 0xf97316,
  background: 0x030712
}

// World outlines loaded from GeoJSON (simplified country boundaries)
let WORLD_OUTLINES = null

export default {
  mounted() {
    this.peers = []
    this.peerMeshes = []
    this.arcLines = []
    this.tooltip = document.getElementById("peer-map-tooltip")
    this.raycaster = new THREE.Raycaster()
    this.mouse = new THREE.Vector2()

    this.setupScene()
    this.createGlobe()
    this.createGridLines()

    // Load world outlines from GeoJSON then draw
    fetch("/world_outlines.json")
      .then(r => r.json())
      .then(data => {
        WORLD_OUTLINES = data
        this.createContinentOutlines()
      })
      .catch(() => {
        console.warn("Could not load world outlines")
      })

    this.animate = this.animate.bind(this)
    this.handleResize = this.handleResize.bind(this)
    this.handleMouseMove = this.handleMouseMove.bind(this)

    window.addEventListener("resize", this.handleResize)
    this.el.addEventListener("mousemove", this.handleMouseMove)

    requestAnimationFrame(this.animate)

    this.handleEvent("peer_map_data", (data) => {
      this.updatePeers(data.peers)
    })
  },

  destroyed() {
    cancelAnimationFrame(this.animationFrame)
    window.removeEventListener("resize", this.handleResize)
    this.el.removeEventListener("mousemove", this.handleMouseMove)
    if (this.renderer) this.renderer.dispose()
  },

  setupScene() {
    const rect = this.el.getBoundingClientRect()
    let width = rect.width || window.innerWidth
    let height = rect.height || window.innerHeight

    // If container hasn't laid out yet, use available viewport space
    if (height < 100) {
      height = window.innerHeight - this.el.getBoundingClientRect().top
    }

    this.scene = new THREE.Scene()
    this.scene.background = new THREE.Color(COLORS.background)

    this.camera = new THREE.PerspectiveCamera(45, width / height, 0.1, 1000)
    this.camera.position.set(0, 30, 130)

    this.renderer = new THREE.WebGLRenderer({ antialias: true })
    this.renderer.setSize(width, height)
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
    this.el.appendChild(this.renderer.domElement)

    this.camera.lookAt(0, 0, 0)

    this.controls = new OrbitControls(this.camera, this.renderer.domElement)
    this.controls.target.set(0, 0, 0)
    this.controls.enableDamping = true
    this.controls.dampingFactor = 0.05
    this.controls.rotateSpeed = 0.5
    this.controls.maxDistance = 300
    this.controls.minDistance = 60
    this.controls.enablePan = false
    // Slow auto-rotate
    this.controls.autoRotate = true
    this.controls.autoRotateSpeed = 0.3

    const ambient = new THREE.AmbientLight(0xffffff, 0.6)
    this.scene.add(ambient)

    const point = new THREE.PointLight(0x4488ff, 2, 500)
    point.position.set(60, 80, 100)
    this.scene.add(point)

    const backLight = new THREE.PointLight(0x2244aa, 1, 400)
    backLight.position.set(-60, -40, -80)
    this.scene.add(backLight)

    this.peerGroup = new THREE.Group()
    this.arcGroup = new THREE.Group()
    this.scene.add(this.peerGroup)
    this.scene.add(this.arcGroup)
  },

  createGlobe() {
    // Wireframe sphere for the globe
    const geometry = new THREE.SphereGeometry(GLOBE_RADIUS, 64, 48)
    const material = new THREE.MeshPhongMaterial({
      color: COLORS.globe,
      emissive: 0x020617,
      emissiveIntensity: 0.35,
      transparent: true,
      opacity: 0.96,
      shininess: 18
    })
    this.globe = new THREE.Mesh(geometry, material)
    this.scene.add(this.globe)

    // Glow ring around globe
    const glowGeometry = new THREE.SphereGeometry(GLOBE_RADIUS + 0.5, 64, 48)
    const glowMaterial = new THREE.MeshBasicMaterial({
      color: COLORS.globeEdge,
      transparent: true,
      opacity: 0.15,
      side: THREE.BackSide
    })
    const glow = new THREE.Mesh(glowGeometry, glowMaterial)
    this.scene.add(glow)

    // Atmosphere halo
    const haloGeometry = new THREE.SphereGeometry(GLOBE_RADIUS + 3, 48, 48)
    const haloMaterial = new THREE.MeshBasicMaterial({
      color: 0x1e40af,
      transparent: true,
      opacity: 0.06,
      side: THREE.BackSide
    })
    this.scene.add(new THREE.Mesh(haloGeometry, haloMaterial))
  },

  createContinentOutlines() {
    if (!WORLD_OUTLINES) return

    const shadowMaterial = new THREE.LineBasicMaterial({
      color: COLORS.landShadow,
      transparent: true,
      opacity: 0.95
    })

    const outlineMaterial = new THREE.LineBasicMaterial({
      color: COLORS.land,
      transparent: true,
      opacity: 0.92
    })

    // Each outline is a ring of [lon, lat] pairs (GeoJSON format)
    WORLD_OUTLINES.forEach((ring) => {
      if (ring.length < 3) return
      const shadowPoints = ring.map(([lon, lat]) => this.latLonToVec3(lat, lon, GLOBE_RADIUS + 0.08))
      const outlinePoints = ring.map(([lon, lat]) => this.latLonToVec3(lat, lon, GLOBE_RADIUS + 0.22))

      const shadowGeometry = new THREE.BufferGeometry().setFromPoints(shadowPoints)
      const outlineGeometry = new THREE.BufferGeometry().setFromPoints(outlinePoints)

      this.scene.add(new THREE.LineLoop(shadowGeometry, shadowMaterial))
      this.scene.add(new THREE.LineLoop(outlineGeometry, outlineMaterial))
    })
  },

  createGridLines() {
    const material = new THREE.LineBasicMaterial({
      color: COLORS.grid,
      transparent: true,
      opacity: 0.25
    })

    // Latitude lines every 30 degrees
    for (let lat = -60; lat <= 60; lat += 30) {
      const points = []
      for (let lon = 0; lon <= 360; lon += 5) {
        points.push(this.latLonToVec3(lat, lon - 180, GLOBE_RADIUS + 0.1))
      }
      const geometry = new THREE.BufferGeometry().setFromPoints(points)
      this.scene.add(new THREE.Line(geometry, material))
    }

    // Longitude lines every 30 degrees
    for (let lon = -180; lon < 180; lon += 30) {
      const points = []
      for (let lat = -90; lat <= 90; lat += 5) {
        points.push(this.latLonToVec3(lat, lon, GLOBE_RADIUS + 0.1))
      }
      const geometry = new THREE.BufferGeometry().setFromPoints(points)
      this.scene.add(new THREE.Line(geometry, material))
    }
  },

  latLonToVec3(lat, lon, radius) {
    const phi = (90 - lat) * (Math.PI / 180)
    const theta = (lon + 180) * (Math.PI / 180)
    const x = -radius * Math.sin(phi) * Math.cos(theta)
    const y = radius * Math.cos(phi)
    const z = radius * Math.sin(phi) * Math.sin(theta)
    return new THREE.Vector3(x, y, z)
  },

  updatePeers(peers) {
    this.clearPeers()
    this.peers = peers.filter((p) => p.lat != null && p.lon != null)

    if (this.peers.length === 0) return

    // Create instanced mesh for peer dots
    const geometry = new THREE.SphereGeometry(DOT_SIZE, 12, 12)
    const material = new THREE.MeshStandardMaterial({
      metalness: 0.4,
      roughness: 0.3,
      emissive: 0x000000,
      emissiveIntensity: 0.3
    })

    this.peerInstancedMesh = new THREE.InstancedMesh(geometry, material, this.peers.length)
    this.peerInstancedMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage)

    const color = new THREE.Color()
    const matrix = new THREE.Matrix4()

    this.peers.forEach((peer, i) => {
      peer._index = i
      const pos = this.latLonToVec3(peer.lat, peer.lon, GLOBE_RADIUS + DOT_SIZE)

      matrix.makeTranslation(pos.x, pos.y, pos.z)
      this.peerInstancedMesh.setMatrixAt(i, matrix)

      color.setHex(peer.inbound ? COLORS.inbound : COLORS.outbound)
      this.peerInstancedMesh.setColorAt(i, color)

      // Create glow ring at peer location
      const glowGeo = new THREE.RingGeometry(DOT_SIZE * 1.5, DOT_SIZE * 2.5, 16)
      const glowMat = new THREE.MeshBasicMaterial({
        color: peer.inbound ? COLORS.inbound : COLORS.outbound,
        transparent: true,
        opacity: 0.25,
        side: THREE.DoubleSide
      })
      const glowMesh = new THREE.Mesh(glowGeo, glowMat)
      glowMesh.position.copy(pos)
      glowMesh.lookAt(0, 0, 0)
      this.peerGroup.add(glowMesh)
      this.peerMeshes.push(glowMesh)

      // Create arc from center of globe surface (our node) to peer
      this.createArc(peer)
    })

    this.peerInstancedMesh.instanceColor.needsUpdate = true
    this.peerGroup.add(this.peerInstancedMesh)
  },

  createArc(peer) {
    // Arc from an arbitrary "home" position to peer
    // We don't know our own location, so draw from globe center projected up
    const peerPos = this.latLonToVec3(peer.lat, peer.lon, GLOBE_RADIUS)

    // Create a great circle arc that rises above the globe surface
    const mid = peerPos.clone().normalize().multiplyScalar(GLOBE_RADIUS + 15 + Math.random() * 10)

    const curve = new THREE.QuadraticBezierCurve3(
      new THREE.Vector3(0, GLOBE_RADIUS + 2, 0),
      mid,
      peerPos.clone().normalize().multiplyScalar(GLOBE_RADIUS + 2)
    )

    const points = curve.getPoints(ARC_SEGMENTS)
    const geometry = new THREE.BufferGeometry().setFromPoints(points)
    const material = new THREE.LineBasicMaterial({
      color: peer.inbound ? COLORS.inbound : COLORS.outbound,
      transparent: true,
      opacity: 0.12
    })

    const line = new THREE.Line(geometry, material)
    this.arcGroup.add(line)
    this.arcLines.push(line)
  },

  clearPeers() {
    if (this.peerInstancedMesh) {
      this.peerGroup.remove(this.peerInstancedMesh)
      this.peerInstancedMesh.geometry.dispose()
      this.peerInstancedMesh.material.dispose()
      this.peerInstancedMesh = null
    }

    this.peerMeshes.forEach((mesh) => {
      this.peerGroup.remove(mesh)
      mesh.geometry.dispose()
      mesh.material.dispose()
    })
    this.peerMeshes = []

    this.arcLines.forEach((line) => {
      this.arcGroup.remove(line)
      line.geometry.dispose()
      line.material.dispose()
    })
    this.arcLines = []

    this.peers = []
  },

  handleResize() {
    if (!this.renderer || !this.camera) return
    const width = this.el.clientWidth || window.innerWidth
    const height = this.el.clientHeight || window.innerHeight
    this.camera.aspect = width / height
    this.camera.updateProjectionMatrix()
    this.renderer.setSize(width, height)
  },

  handleMouseMove(event) {
    if (!this.peerInstancedMesh || !this.renderer) return

    const rect = this.renderer.domElement.getBoundingClientRect()
    this.mouse.x = ((event.clientX - rect.left) / rect.width) * 2 - 1
    this.mouse.y = -((event.clientY - rect.top) / rect.height) * 2 + 1

    this.raycaster.setFromCamera(this.mouse, this.camera)
    const intersects = this.raycaster.intersectObject(this.peerInstancedMesh)

    if (intersects.length > 0) {
      const instanceId = intersects[0].instanceId
      const peer = this.peers.find((p) => p._index === instanceId)

      if (peer && this.tooltip) {
        const ping = peer.pingtime ? (peer.pingtime * 1000).toFixed(0) + "ms" : "n/a"
        const sent = formatBytes(peer.bytessent || 0)
        const recv = formatBytes(peer.bytesrecv || 0)
        const location = [peer.city, peer.country].filter(Boolean).join(", ") || "Unknown"

        this.tooltip.innerHTML = `
          <div class="font-mono font-semibold mb-1">${peer.ip}</div>
          <div>${location}</div>
          <div>${peer.inbound ? "Inbound" : "Outbound"} &middot; Ping: ${ping}</div>
          <div>Sent: ${sent} &middot; Recv: ${recv}</div>
          <div class="text-neutral-400 mt-1">${(peer.subver || "").replace(/\//g, "")}</div>
          ${peer.isp ? `<div class="text-neutral-500">${peer.isp}</div>` : ""}
        `
        this.tooltip.style.left = event.clientX + 12 + "px"
        this.tooltip.style.top = event.clientY - 10 + "px"
        this.tooltip.classList.remove("hidden")

        // Stop auto-rotate while hovering
        this.controls.autoRotate = false
        return
      }
    }

    if (this.tooltip) this.tooltip.classList.add("hidden")
    this.controls.autoRotate = true
  },

  animate() {
    this.animationFrame = requestAnimationFrame(this.animate)

    // Pulse the peer glow rings
    const time = performance.now() * 0.001
    this.peerMeshes.forEach((mesh, i) => {
      const pulse = 0.15 + Math.sin(time * 2 + i * 0.5) * 0.1
      mesh.material.opacity = pulse
    })

    if (this.controls) this.controls.update()
    if (this.renderer && this.scene && this.camera) {
      this.renderer.render(this.scene, this.camera)
    }
  }
}

function formatBytes(bytes) {
  if (bytes < 1024) return bytes + " B"
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB"
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + " MB"
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB"
}
