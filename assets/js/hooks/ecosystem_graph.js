import * as THREE from "three"
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js"

const CATEGORY_COLORS = {
  network: 0xfbbf24,
  data_storage: 0x3b82f6,
  identity: 0x22c55e,
  token: 0xa855f7,
  bearer_asset: 0xa855f7,
  constraint: 0xf43f5e,
  access_control: 0xf43f5e,
  multi_party: 0xf97316,
  credential: 0x22c55e,
  other: 0x6b7280
}

const DEPRECATED_COLOR = 0x6b7280

export default {
  mounted() {
    this.nodes = new Map()
    this.edges = []
    this.nodePositions = new Map()
    this.raycaster = new THREE.Raycaster()
    this.mouse = new THREE.Vector2()
    this.tooltip = document.getElementById("ecosystem-tooltip")
    this.labels = []

    this.setupScene()
    this.animate = this.animate.bind(this)
    this.handleResize = this.handleResize.bind(this)
    this.handleMouseMove = this.handleMouseMove.bind(this)
    this.handleClick = this.handleClick.bind(this)

    window.addEventListener("resize", this.handleResize)
    this.el.addEventListener("mousemove", this.handleMouseMove)
    this.el.addEventListener("click", this.handleClick)

    requestAnimationFrame(this.animate)

    this.handleEvent("ecosystem_data", (data) => {
      this.loadData(data)
    })
  },

  destroyed() {
    cancelAnimationFrame(this.animationFrame)
    window.removeEventListener("resize", this.handleResize)
    this.el.removeEventListener("mousemove", this.handleMouseMove)
    this.el.removeEventListener("click", this.handleClick)
    if (this.renderer) this.renderer.dispose()
  },

  setupScene() {
    const width = this.el.clientWidth || window.innerWidth
    const height = this.el.clientHeight || window.innerHeight

    this.scene = new THREE.Scene()
    this.scene.background = new THREE.Color(0x050608)

    this.camera = new THREE.PerspectiveCamera(60, width / height, 0.1, 5000)
    this.camera.position.set(0, 30, 80)

    this.renderer = new THREE.WebGLRenderer({ antialias: true })
    this.renderer.setSize(width, height)
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
    this.el.replaceChildren(this.renderer.domElement)

    this.controls = new OrbitControls(this.camera, this.renderer.domElement)
    this.controls.enableDamping = true
    this.controls.dampingFactor = 0.08
    this.controls.maxDistance = 300
    this.controls.minDistance = 10

    const ambient = new THREE.AmbientLight(0xffffff, 0.6)
    this.scene.add(ambient)
    const directional = new THREE.DirectionalLight(0xffffff, 0.9)
    directional.position.set(40, 60, 80)
    this.scene.add(directional)

    this.nodeGroup = new THREE.Group()
    this.edgeGroup = new THREE.Group()
    this.labelGroup = new THREE.Group()
    this.scene.add(this.edgeGroup)
    this.scene.add(this.nodeGroup)
    this.scene.add(this.labelGroup)
  },

  loadData(data) {
    this.clearScene()

    const { nodes, edges } = data
    this.edges = edges

    nodes.forEach((node, i) => {
      node._index = i
      this.nodes.set(node.id, node)
    })

    // Force-directed layout
    this.computeLayout(nodes, edges)

    // Create visuals
    this.createNodes(nodes)
    this.createEdges(edges)
    this.createLabels(nodes)

    this.fitCamera()
  },

  computeLayout(nodes, edges) {
    // Initialize positions in a sphere
    const positions = new Map()
    nodes.forEach((node) => {
      const theta = Math.random() * Math.PI * 2
      const phi = Math.acos(2 * Math.random() - 1)
      const r = 20 + Math.random() * 10
      positions.set(node.id, new THREE.Vector3(
        r * Math.sin(phi) * Math.cos(theta),
        r * Math.sin(phi) * Math.sin(theta),
        r * Math.cos(phi)
      ))
    })

    // Pin BSV at center
    if (positions.has("bsv")) {
      positions.set("bsv", new THREE.Vector3(0, 0, 0))
    }

    // Build adjacency
    const neighbors = new Map()
    nodes.forEach((n) => neighbors.set(n.id, []))
    edges.forEach((e) => {
      if (neighbors.has(e.from)) neighbors.get(e.from).push(e.to)
      if (neighbors.has(e.to)) neighbors.get(e.to).push(e.from)
    })

    const velocities = new Map()
    nodes.forEach((n) => velocities.set(n.id, new THREE.Vector3()))

    const iterations = 100
    const repulsion = 15.0
    const attraction = 0.04
    const damping = 0.85

    for (let iter = 0; iter < iterations; iter++) {
      const temp = 1.0 - iter / iterations

      // Repulsion
      for (let i = 0; i < nodes.length; i++) {
        const a = nodes[i]
        if (a.id === "bsv") continue
        const posA = positions.get(a.id)
        const vel = velocities.get(a.id)

        for (let j = 0; j < nodes.length; j++) {
          if (i === j) continue
          const b = nodes[j]
          const posB = positions.get(b.id)

          const dx = posA.x - posB.x
          const dy = posA.y - posB.y
          const dz = posA.z - posB.z
          const dist = Math.sqrt(dx * dx + dy * dy + dz * dz) + 0.1

          const force = repulsion / (dist * dist)
          vel.x += (dx / dist) * force * temp
          vel.y += (dy / dist) * force * temp
          vel.z += (dz / dist) * force * temp
        }
      }

      // Attraction along edges
      edges.forEach((e) => {
        const posFrom = positions.get(e.from)
        const posTo = positions.get(e.to)
        if (!posFrom || !posTo) return

        const dx = posTo.x - posFrom.x
        const dy = posTo.y - posFrom.y
        const dz = posTo.z - posFrom.z

        if (e.from !== "bsv") {
          const velFrom = velocities.get(e.from)
          velFrom.x += dx * attraction
          velFrom.y += dy * attraction
          velFrom.z += dz * attraction
        }
        if (e.to !== "bsv") {
          const velTo = velocities.get(e.to)
          velTo.x -= dx * attraction
          velTo.y -= dy * attraction
          velTo.z -= dz * attraction
        }
      })

      // Apply velocities
      nodes.forEach((n) => {
        if (n.id === "bsv") return
        const pos = positions.get(n.id)
        const vel = velocities.get(n.id)
        pos.add(vel)
        vel.multiplyScalar(damping)
      })
    }

    this.nodePositions = positions
  },

  createNodes(nodes) {
    const geometry = new THREE.SphereGeometry(1, 16, 16)
    const material = new THREE.MeshStandardMaterial({
      metalness: 0.3,
      roughness: 0.5
    })

    this.instancedMesh = new THREE.InstancedMesh(geometry, material, nodes.length)
    this.instancedMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage)

    const color = new THREE.Color()
    const matrix = new THREE.Matrix4()
    const scaleMatrix = new THREE.Matrix4()

    nodes.forEach((node) => {
      const pos = this.nodePositions.get(node.id)
      if (!pos) return

      // Size: BSV is the biggest, others based on connectivity
      const isCenter = node.id === "bsv"
      const scale = isCenter ? 3.0 : 1.2

      if (node.status === "deprecated") {
        color.setHex(DEPRECATED_COLOR)
      } else {
        color.setHex(CATEGORY_COLORS[node.category] || CATEGORY_COLORS.other)
      }

      matrix.makeTranslation(pos.x, pos.y, pos.z)
      scaleMatrix.makeScale(scale, scale, scale)
      matrix.multiply(scaleMatrix)

      this.instancedMesh.setMatrixAt(node._index, matrix)
      this.instancedMesh.setColorAt(node._index, color)
    })

    this.instancedMesh.instanceColor.needsUpdate = true
    this.nodeGroup.add(this.instancedMesh)
  },

  createEdges(edges) {
    if (edges.length === 0) return

    const positions = new Float32Array(edges.length * 6)

    edges.forEach((edge, i) => {
      const from = this.nodePositions.get(edge.from)
      const to = this.nodePositions.get(edge.to)
      if (!from || !to) return

      const offset = i * 6
      positions[offset] = from.x
      positions[offset + 1] = from.y
      positions[offset + 2] = from.z
      positions[offset + 3] = to.x
      positions[offset + 4] = to.y
      positions[offset + 5] = to.z
    })

    const geometry = new THREE.BufferGeometry()
    geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3))

    const material = new THREE.LineBasicMaterial({
      color: 0x475569,
      transparent: true,
      opacity: 0.3
    })

    this.edgeLineSegments = new THREE.LineSegments(geometry, material)
    this.edgeGroup.add(this.edgeLineSegments)
  },

  createLabels(nodes) {
    // Create text sprite labels for each node
    nodes.forEach((node) => {
      const pos = this.nodePositions.get(node.id)
      if (!pos) return

      const canvas = document.createElement("canvas")
      const ctx = canvas.getContext("2d")
      const text = node.name
      const fontSize = node.id === "bsv" ? 28 : 16

      ctx.font = `bold ${fontSize}px -apple-system, sans-serif`
      const metrics = ctx.measureText(text)
      const textWidth = metrics.width

      canvas.width = textWidth + 16
      canvas.height = fontSize + 12

      ctx.font = `bold ${fontSize}px -apple-system, sans-serif`
      ctx.fillStyle = node.status === "deprecated" ? "#6b7280" : "#e5e5e5"
      ctx.textAlign = "center"
      ctx.textBaseline = "middle"
      ctx.fillText(text, canvas.width / 2, canvas.height / 2)

      const texture = new THREE.CanvasTexture(canvas)
      texture.minFilter = THREE.LinearFilter

      const spriteMaterial = new THREE.SpriteMaterial({
        map: texture,
        transparent: true,
        depthTest: false
      })

      const sprite = new THREE.Sprite(spriteMaterial)
      const spriteScale = node.id === "bsv" ? 12 : 6
      sprite.scale.set(
        spriteScale * (canvas.width / canvas.height),
        spriteScale,
        1
      )

      const labelOffset = node.id === "bsv" ? 5 : 2.5
      sprite.position.set(pos.x, pos.y + labelOffset, pos.z)

      this.labelGroup.add(sprite)
      this.labels.push(sprite)
    })
  },

  fitCamera() {
    const box = new THREE.Box3()
    this.nodePositions.forEach((pos) => box.expandByPoint(pos))
    if (box.isEmpty()) return

    const center = box.getCenter(new THREE.Vector3())
    const size = box.getSize(new THREE.Vector3())
    const maxDim = Math.max(size.x, size.y, size.z)

    this.controls.target.copy(center)
    this.camera.position.set(
      center.x + maxDim * 0.4,
      center.y + maxDim * 0.3,
      center.z + maxDim * 0.7
    )
    this.controls.update()
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
    if (!this.renderer || !this.instancedMesh) return

    const rect = this.renderer.domElement.getBoundingClientRect()
    this.mouse.x = ((event.clientX - rect.left) / rect.width) * 2 - 1
    this.mouse.y = -((event.clientY - rect.top) / rect.height) * 2 + 1

    this.raycaster.setFromCamera(this.mouse, this.camera)
    const intersects = this.raycaster.intersectObject(this.instancedMesh)

    if (intersects.length > 0) {
      const instanceId = intersects[0].instanceId
      const node = Array.from(this.nodes.values()).find((n) => n._index === instanceId)

      if (node && this.tooltip) {
        const statusBadge = node.status === "deprecated"
          ? '<span class="text-neutral-500">(deprecated)</span>'
          : '<span class="text-green-400">(active)</span>'
        this.tooltip.innerHTML = `
          <div class="font-semibold mb-1">${node.name} ${statusBadge}</div>
          <div class="text-neutral-400 mb-1">${node.category}</div>
          <div>${node.description}</div>
        `
        this.tooltip.style.left = event.clientX + 12 + "px"
        this.tooltip.style.top = event.clientY - 10 + "px"
        this.tooltip.classList.remove("hidden")
        this.renderer.domElement.style.cursor = "pointer"
        return
      }
    }

    if (this.tooltip) this.tooltip.classList.add("hidden")
    this.renderer.domElement.style.cursor = "default"
  },

  handleClick(event) {
    if (!this.instancedMesh) return

    const rect = this.renderer.domElement.getBoundingClientRect()
    this.mouse.x = ((event.clientX - rect.left) / rect.width) * 2 - 1
    this.mouse.y = -((event.clientY - rect.top) / rect.height) * 2 + 1

    this.raycaster.setFromCamera(this.mouse, this.camera)
    const intersects = this.raycaster.intersectObject(this.instancedMesh)

    if (intersects.length > 0) {
      const instanceId = intersects[0].instanceId
      const node = Array.from(this.nodes.values()).find((n) => n._index === instanceId)
      if (node) {
        this.pushEvent("node_selected", { id: node.id, name: node.name })
        return
      }
    }

    this.pushEvent("node_deselected", {})
  },

  clearScene() {
    if (this.instancedMesh) {
      this.nodeGroup.remove(this.instancedMesh)
      this.instancedMesh.geometry.dispose()
      this.instancedMesh.material.dispose()
      this.instancedMesh = null
    }

    if (this.edgeLineSegments) {
      this.edgeGroup.remove(this.edgeLineSegments)
      this.edgeLineSegments.geometry.dispose()
      this.edgeLineSegments.material.dispose()
      this.edgeLineSegments = null
    }

    this.labels.forEach((sprite) => {
      this.labelGroup.remove(sprite)
      sprite.material.map.dispose()
      sprite.material.dispose()
    })
    this.labels = []

    this.nodes.clear()
    this.edges = []
    this.nodePositions.clear()
  },

  animate() {
    this.animationFrame = requestAnimationFrame(this.animate)
    if (this.controls) this.controls.update()
    if (this.renderer && this.scene && this.camera) {
      this.renderer.render(this.scene, this.camera)
    }
  }
}
