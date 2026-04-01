import * as THREE from "three"
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js"

const COLORS = {
  coinbase: 0xfbbf24,
  regular: 0x3b82f6,
  highValue: 0x22c55e,
  edge: 0x475569,
  edgeHighlight: 0xf97316,
  blockFar: 0x6366f1,
  blockMedium: 0x8b5cf6,
  genesis: 0xf59e0b,
  background: 0x050608
}

const LAYOUT = {
  blockSpacing: 8,
  txSpacing: 2.5,
  txsPerRow: 20,
  nodeRadius: 0.8,
  blockNodeRadius: 3.0,
  transitionDuration: 500
}

// Zoom level thresholds (camera distance)
const ZOOM = {
  far: 500,    // > 500: show blocks as single nodes
  medium: 150, // 150-500: show transaction clusters
  close: 0     // < 150: show individual transactions with full detail
}

export default {
  mounted() {
    this.nodes = new Map()
    this.edges = []
    this.blockData = []
    this.instancedMesh = null
    this.blockInstancedMesh = null
    this.hoveredNode = null
    this.layoutMode = this.el.dataset.layout || "time"
    this.targetPositions = new Map()
    this.transitioning = false
    this.transitionStart = 0
    this.raycaster = new THREE.Raycaster()
    this.mouse = new THREE.Vector2()
    this.tooltip = document.getElementById("block-graph-tooltip")
    this.zoomIndicator = document.getElementById("zoom-indicator")
    this.currentZoomLevel = "close"
    this.lodDirty = true

    this.setupScene()
    this.animate = this.animate.bind(this)
    this.handleResize = this.handleResize.bind(this)
    this.handleMouseMove = this.handleMouseMove.bind(this)

    window.addEventListener("resize", this.handleResize)
    this.el.addEventListener("mousemove", this.handleMouseMove)

    requestAnimationFrame(this.animate)

    this.handleEvent("block_graph_data", (data) => {
      this.loadGraphData(data)
    })

    this.handleEvent("block_graph_layout", (data) => {
      this.setLayout(data.mode)
    })

    this.handleEvent("block_graph_playback", (data) => {
      this.handlePlayback(data)
    })

    // Playback state
    this.playbackState = "stopped" // stopped | playing | paused
    this.playbackCursor = 0
    this.playbackSpeed = 800 // ms per block
    this.playbackTimer = null
  },

  destroyed() {
    cancelAnimationFrame(this.animationFrame)
    this.stopPlaybackTimer()
    window.removeEventListener("resize", this.handleResize)
    this.el.removeEventListener("mousemove", this.handleMouseMove)
    if (this.renderer) {
      this.renderer.dispose()
    }
  },

  setupScene() {
    const width = this.el.clientWidth || window.innerWidth
    const height = this.el.clientHeight || window.innerHeight

    this.scene = new THREE.Scene()
    this.scene.background = new THREE.Color(COLORS.background)

    this.camera = new THREE.PerspectiveCamera(60, width / height, 0.1, 50000)
    this.camera.position.set(50, 40, 120)

    this.renderer = new THREE.WebGLRenderer({ antialias: true })
    this.renderer.setSize(width, height)
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
    this.el.replaceChildren(this.renderer.domElement)

    if (!document.getElementById("block-graph-tooltip")) {
      document.body.appendChild(this.tooltip)
    }

    this.controls = new OrbitControls(this.camera, this.renderer.domElement)
    this.controls.enableDamping = true
    this.controls.dampingFactor = 0.08
    this.controls.maxDistance = 5000
    this.controls.minDistance = 5

    const ambient = new THREE.AmbientLight(0xffffff, 0.6)
    this.scene.add(ambient)

    const directional = new THREE.DirectionalLight(0xffffff, 0.9)
    directional.position.set(80, 120, 160)
    this.scene.add(directional)

    // LOD groups
    this.txGroup = new THREE.Group()       // individual transactions (close zoom)
    this.blockGroup = new THREE.Group()    // block summary nodes (far zoom)
    this.edgeGroup = new THREE.Group()     // edges between transactions
    this.blockEdgeGroup = new THREE.Group() // edges between blocks (far zoom)

    this.scene.add(this.edgeGroup)
    this.scene.add(this.blockEdgeGroup)
    this.scene.add(this.txGroup)
    this.scene.add(this.blockGroup)
  },

  loadGraphData(data) {
    this.clearScene()

    this.graphData = data
    const { nodes, edges, blocks } = data

    this.blockData = blocks || []

    // Store node data
    nodes.forEach((node, i) => {
      node._index = i
      this.nodes.set(node.id, node)
    })
    this.edges = edges

    // Create both LOD levels
    if (nodes.length > 0) {
      this.createInstancedNodes(nodes)
      this.createEdgeLines(edges)
    }

    if (this.blockData.length > 0) {
      this.createBlockNodes(this.blockData)
      this.createBlockEdges(this.blockData)
    }

    this.applyLayout(this.layoutMode, false)
    this.fitCamera()
    this.lodDirty = true
  },

  createInstancedNodes(nodes) {
    const geometry = new THREE.SphereGeometry(LAYOUT.nodeRadius, 12, 12)
    const material = new THREE.MeshStandardMaterial({
      metalness: 0.2,
      roughness: 0.6
    })

    this.instancedMesh = new THREE.InstancedMesh(geometry, material, nodes.length)
    this.instancedMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage)

    const color = new THREE.Color()
    const matrix = new THREE.Matrix4()

    nodes.forEach((node, i) => {
      if (node.type === "coinbase") {
        color.setHex(COLORS.coinbase)
        matrix.makeScale(1.6, 1.6, 1.6)
      } else if (node.total_out && node.total_out > 100_000_000) {
        color.setHex(COLORS.highValue)
        matrix.makeScale(1.0, 1.0, 1.0)
      } else {
        color.setHex(COLORS.regular)
        matrix.makeScale(1.0, 1.0, 1.0)
      }

      // Dim spent outputs to distinguish from unspent (live UTXOs)
      if (node.spent) {
        color.multiplyScalar(0.4)
      }

      this.instancedMesh.setColorAt(i, color)
      this.instancedMesh.setMatrixAt(i, matrix)
    })
    this.instancedMesh.instanceColor.needsUpdate = true

    this.txGroup.add(this.instancedMesh)
  },

  createBlockNodes(blocks) {
    if (blocks.length === 0) return

    const geometry = new THREE.BoxGeometry(
      LAYOUT.blockNodeRadius * 2,
      LAYOUT.blockNodeRadius * 2,
      LAYOUT.blockNodeRadius * 2
    )
    const material = new THREE.MeshStandardMaterial({
      metalness: 0.3,
      roughness: 0.5
    })

    this.blockInstancedMesh = new THREE.InstancedMesh(geometry, material, blocks.length)
    this.blockInstancedMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage)

    const color = new THREE.Color()
    const matrix = new THREE.Matrix4()

    blocks.forEach((block, i) => {
      block._blockIndex = i

      const isGenesis = block.height === 0

      // Color: genesis gets special golden treatment
      if (isGenesis) {
        color.setHex(COLORS.genesis)
      } else {
        const txCount = block.tx_count || 0
        if (txCount === 0) {
          color.setHex(0x374151) // gray for empty
        } else if (txCount === 1) {
          color.setHex(COLORS.blockFar)
        } else {
          color.setHex(COLORS.blockMedium)
        }
      }
      this.blockInstancedMesh.setColorAt(i, color)

      // Scale: genesis is larger, others scale by tx count (log scale)
      const txCount = block.tx_count || 0
      const scale = isGenesis
        ? 1.8
        : 0.5 + Math.log2(Math.max(1, txCount)) * 0.3
      matrix.makeScale(scale, scale, scale)
      this.blockInstancedMesh.setMatrixAt(i, matrix)
    })

    this.blockInstancedMesh.instanceColor.needsUpdate = true
    this.blockGroup.add(this.blockInstancedMesh)
  },

  createBlockEdges(blocks) {
    if (blocks.length < 2) return

    const positions = new Float32Array((blocks.length - 1) * 6)
    this.blockEdgePositions = positions

    const geometry = new THREE.BufferGeometry()
    geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3))

    const material = new THREE.LineBasicMaterial({
      color: 0x6366f1,
      transparent: true,
      opacity: 0.5
    })

    this.blockEdgeLineSegments = new THREE.LineSegments(geometry, material)
    this.blockEdgeGroup.add(this.blockEdgeLineSegments)
  },

  createEdgeLines(edges) {
    if (edges.length === 0) return

    const positions = new Float32Array(edges.length * 6)
    this.edgePositions = positions

    const geometry = new THREE.BufferGeometry()
    geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3))

    const material = new THREE.LineBasicMaterial({
      color: COLORS.edge,
      transparent: true,
      opacity: 0.35
    })

    this.edgeLineSegments = new THREE.LineSegments(geometry, material)
    this.edgeGroup.add(this.edgeLineSegments)
  },

  applyLayout(mode, animate = true) {
    this.layoutMode = mode
    const nodes = Array.from(this.nodes.values())

    if (nodes.length === 0 && this.blockData.length === 0) return

    let positions
    switch (mode) {
      case "force":
        positions = this.forceLayout(nodes)
        break
      case "hierarchical":
        positions = this.hierarchicalLayout(nodes)
        break
      case "time":
      default:
        positions = this.timeLayout(nodes)
        break
    }

    // Compute block positions (always time-based for blocks)
    this.blockPositions = this.blockTimeLayout(this.blockData, nodes)

    if (animate && this.currentPositions) {
      this.startTransition(positions)
    } else {
      this.applyPositions(positions)
    }

    this.applyBlockPositions(this.blockPositions)
    this.lodDirty = true
  },

  blockTimeLayout(blocks, nodes) {
    const positions = new Map()
    if (blocks.length === 0) return positions

    const minHeight = blocks[0].height

    blocks.forEach((block) => {
      const x = (block.height - minHeight) * LAYOUT.blockSpacing
      positions.set(block.height, new THREE.Vector3(x, 0, 0))
    })

    return positions
  },

  timeLayout(nodes) {
    const positions = new Map()
    const blockGroups = new Map()

    nodes.forEach((node) => {
      const h = node.block_height
      if (!blockGroups.has(h)) blockGroups.set(h, [])
      blockGroups.get(h).push(node)
    })

    const sortedHeights = Array.from(blockGroups.keys()).sort((a, b) => a - b)
    const minHeight = sortedHeights[0] || 0

    sortedHeights.forEach((height) => {
      const group = blockGroups.get(height)
      const x = (height - minHeight) * LAYOUT.blockSpacing

      group.forEach((node, idx) => {
        const row = Math.floor(idx / LAYOUT.txsPerRow)
        const col = idx % LAYOUT.txsPerRow
        const y = col * LAYOUT.txSpacing
        const z = -row * LAYOUT.txSpacing

        positions.set(node.id, new THREE.Vector3(x, y, z))
      })
    })

    return positions
  },

  forceLayout(nodes) {
    const positions = new Map()
    const initial = this.timeLayout(nodes)

    initial.forEach((pos, id) => {
      positions.set(id, pos.clone())
    })

    const neighbors = new Map()
    nodes.forEach((n) => neighbors.set(n.id, []))
    this.edges.forEach((e) => {
      if (neighbors.has(e.from) && neighbors.has(e.to)) {
        neighbors.get(e.from).push(e.to)
        neighbors.get(e.to).push(e.from)
      }
    })

    const iterations = 50
    const repulsion = 8.0
    const attraction = 0.05
    const damping = 0.9

    const velocities = new Map()
    nodes.forEach((n) => velocities.set(n.id, new THREE.Vector3()))

    for (let iter = 0; iter < iterations; iter++) {
      const temp = 1.0 - iter / iterations

      for (let i = 0; i < nodes.length; i++) {
        const a = nodes[i]
        const posA = positions.get(a.id)
        const vel = velocities.get(a.id)

        const sampleSize = Math.min(nodes.length, 50)
        const step = Math.max(1, Math.floor(nodes.length / sampleSize))

        for (let j = 0; j < nodes.length; j += step) {
          if (i === j) continue
          const b = nodes[j]
          const posB = positions.get(b.id)

          const dx = posA.x - posB.x
          const dy = posA.y - posB.y
          const dz = posA.z - posB.z
          const dist = Math.sqrt(dx * dx + dy * dy + dz * dz) + 0.1

          const force = (repulsion * step) / (dist * dist)
          vel.x += (dx / dist) * force * temp
          vel.y += (dy / dist) * force * temp
          vel.z += (dz / dist) * force * temp
        }
      }

      this.edges.forEach((e) => {
        const posFrom = positions.get(e.from)
        const posTo = positions.get(e.to)
        if (!posFrom || !posTo) return

        const dx = posTo.x - posFrom.x
        const dy = posTo.y - posFrom.y
        const dz = posTo.z - posFrom.z

        const velFrom = velocities.get(e.from)
        const velTo = velocities.get(e.to)

        if (velFrom) {
          velFrom.x += dx * attraction
          velFrom.y += dy * attraction
          velFrom.z += dz * attraction
        }
        if (velTo) {
          velTo.x -= dx * attraction
          velTo.y -= dy * attraction
          velTo.z -= dz * attraction
        }
      })

      nodes.forEach((n) => {
        const pos = positions.get(n.id)
        const vel = velocities.get(n.id)
        pos.add(vel)
        vel.multiplyScalar(damping)
      })
    }

    return positions
  },

  hierarchicalLayout(nodes) {
    const positions = new Map()

    const coinbases = nodes.filter((n) => n.type === "coinbase")

    const depths = new Map()
    coinbases.forEach((n) => depths.set(n.id, 0))

    const queue = coinbases.map((n) => n.id)
    const adjacency = new Map()
    this.edges.forEach((e) => {
      if (!adjacency.has(e.from)) adjacency.set(e.from, [])
      adjacency.get(e.from).push(e.to)
    })

    while (queue.length > 0) {
      const current = queue.shift()
      const currentDepth = depths.get(current) || 0
      const children = adjacency.get(current) || []

      children.forEach((child) => {
        if (!depths.has(child)) {
          depths.set(child, currentDepth + 1)
          queue.push(child)
        }
      })
    }

    nodes.forEach((n) => {
      if (!depths.has(n.id)) depths.set(n.id, 0)
    })

    const depthGroups = new Map()
    nodes.forEach((n) => {
      const d = depths.get(n.id)
      if (!depthGroups.has(d)) depthGroups.set(d, [])
      depthGroups.get(d).push(n)
    })

    depthGroups.forEach((group, depth) => {
      group.forEach((node, idx) => {
        const row = Math.floor(idx / LAYOUT.txsPerRow)
        const col = idx % LAYOUT.txsPerRow
        const x = col * LAYOUT.txSpacing
        const y = -depth * LAYOUT.blockSpacing
        const z = -row * LAYOUT.txSpacing

        positions.set(node.id, new THREE.Vector3(x, y, z))
      })
    })

    return positions
  },

  startTransition(targetPositions) {
    this.targetPositions = targetPositions
    this.transitionStart = performance.now()
    this.transitioning = true

    this.startPositions = new Map()
    const matrix = new THREE.Matrix4()
    const pos = new THREE.Vector3()

    this.nodes.forEach((node) => {
      if (this.instancedMesh) {
        this.instancedMesh.getMatrixAt(node._index, matrix)
        pos.setFromMatrixPosition(matrix)
        this.startPositions.set(node.id, pos.clone())
      }
    })
  },

  applyPositions(positions) {
    if (!this.instancedMesh) return

    const matrix = new THREE.Matrix4()
    const scaleMatrix = new THREE.Matrix4()

    this.nodes.forEach((node) => {
      const pos = positions.get(node.id)
      if (!pos) return
      const scale = node.type === "coinbase" ? 1.6 : 1.0
      matrix.makeTranslation(pos.x, pos.y, pos.z)
      scaleMatrix.makeScale(scale, scale, scale)
      matrix.multiply(scaleMatrix)
      this.instancedMesh.setMatrixAt(node._index, matrix)
    })
    this.instancedMesh.instanceMatrix.needsUpdate = true

    this.updateEdgePositions(positions)
    this.currentPositions = positions
  },

  applyBlockPositions(positions) {
    if (!this.blockInstancedMesh || this.blockData.length === 0) return

    const matrix = new THREE.Matrix4()
    const scaleMatrix = new THREE.Matrix4()

    this.blockData.forEach((block) => {
      const pos = positions.get(block.height)
      if (!pos) return
      const txCount = block.tx_count || 0
      const scale = 0.5 + Math.log2(Math.max(1, txCount)) * 0.3
      matrix.makeTranslation(pos.x, pos.y, pos.z)
      scaleMatrix.makeScale(scale, scale, scale)
      matrix.multiply(scaleMatrix)
      this.blockInstancedMesh.setMatrixAt(block._blockIndex, matrix)
    })
    this.blockInstancedMesh.instanceMatrix.needsUpdate = true

    // Update block edges
    this.updateBlockEdgePositions(positions)
  },

  updateBlockEdgePositions(positions) {
    if (!this.blockEdgeLineSegments || this.blockData.length < 2) return

    const posArray = this.blockEdgePositions
    const sorted = [...this.blockData].sort((a, b) => a.height - b.height)

    for (let i = 0; i < sorted.length - 1; i++) {
      const from = positions.get(sorted[i].height)
      const to = positions.get(sorted[i + 1].height)

      if (from && to) {
        const offset = i * 6
        posArray[offset] = from.x
        posArray[offset + 1] = from.y
        posArray[offset + 2] = from.z
        posArray[offset + 3] = to.x
        posArray[offset + 4] = to.y
        posArray[offset + 5] = to.z
      }
    }

    this.blockEdgeLineSegments.geometry.attributes.position.needsUpdate = true
    this.blockEdgeLineSegments.geometry.computeBoundingSphere()
  },

  updateEdgePositions(positions) {
    if (!this.edgeLineSegments || this.edges.length === 0) return

    const posArray = this.edgePositions
    this.edges.forEach((edge, i) => {
      const from = positions.get(edge.from)
      const to = positions.get(edge.to)

      if (from && to) {
        const offset = i * 6
        posArray[offset] = from.x
        posArray[offset + 1] = from.y
        posArray[offset + 2] = from.z
        posArray[offset + 3] = to.x
        posArray[offset + 4] = to.y
        posArray[offset + 5] = to.z
      }
    })

    this.edgeLineSegments.geometry.attributes.position.needsUpdate = true
    this.edgeLineSegments.geometry.computeBoundingSphere()
  },

  setLayout(mode) {
    this.applyLayout(mode, true)
  },

  // Progressive disclosure: update LOD based on camera distance
  updateLOD() {
    const dist = this.camera.position.distanceTo(this.controls.target)
    let newLevel

    if (dist > ZOOM.far) {
      newLevel = "far"
    } else if (dist > ZOOM.medium) {
      newLevel = "medium"
    } else {
      newLevel = "close"
    }

    if (newLevel !== this.currentZoomLevel || this.lodDirty) {
      this.currentZoomLevel = newLevel
      this.lodDirty = false

      switch (newLevel) {
        case "far":
          // Show only block summary nodes
          this.txGroup.visible = false
          this.edgeGroup.visible = false
          this.blockGroup.visible = true
          this.blockEdgeGroup.visible = true
          break

        case "medium":
          // Show both blocks and transactions, but transactions are smaller context
          this.txGroup.visible = true
          this.edgeGroup.visible = false
          this.blockGroup.visible = true
          this.blockEdgeGroup.visible = true
          break

        case "close":
          // Show individual transactions with edges
          this.txGroup.visible = true
          this.edgeGroup.visible = true
          this.blockGroup.visible = false
          this.blockEdgeGroup.visible = false
          break
      }

      // Update zoom indicator
      if (this.zoomIndicator) {
        const labels = {
          far: "Block overview &middot; Zoom in for transactions",
          medium: "Transaction clusters &middot; Zoom in for connections",
          close: "Full detail &middot; Scroll to zoom &middot; Drag to pan"
        }
        const colors = {
          far: "bg-indigo-500",
          medium: "bg-purple-500",
          close: "bg-blue-500"
        }
        this.zoomIndicator.innerHTML = `
          <span class="w-2 h-2 rounded-full ${colors[newLevel]}"></span>
          <span>${labels[newLevel]}</span>
        `
      }
    }
  },

  fitCamera() {
    if (!this.currentPositions && !this.blockPositions) return

    const box = new THREE.Box3()

    if (this.currentPositions) {
      this.currentPositions.forEach((pos) => box.expandByPoint(pos))
    }
    if (this.blockPositions) {
      this.blockPositions.forEach((pos) => box.expandByPoint(pos))
    }

    if (box.isEmpty()) return

    const center = box.getCenter(new THREE.Vector3())
    const size = box.getSize(new THREE.Vector3())
    const maxDim = Math.max(size.x, size.y, size.z)

    this.controls.target.copy(center)
    this.camera.position.set(
      center.x + maxDim * 0.5,
      center.y + maxDim * 0.4,
      center.z + maxDim * 0.8
    )
    this.controls.update()
    this.lodDirty = true
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
    if (!this.renderer) return

    const rect = this.renderer.domElement.getBoundingClientRect()
    this.mouse.x = ((event.clientX - rect.left) / rect.width) * 2 - 1
    this.mouse.y = -((event.clientY - rect.top) / rect.height) * 2 + 1

    this.raycaster.setFromCamera(this.mouse, this.camera)

    // Check which LOD level is visible and raycast accordingly
    if (this.currentZoomLevel === "far" && this.blockInstancedMesh) {
      const intersects = this.raycaster.intersectObject(this.blockInstancedMesh)
      if (intersects.length > 0) {
        const instanceId = intersects[0].instanceId
        const block = this.blockData.find((b) => b._blockIndex === instanceId)

        if (block && this.tooltip) {
          const bsv = ((block.total_value || 0) / 100_000_000).toFixed(4)
          this.tooltip.innerHTML = `
            <div class="font-semibold mb-1">Block ${block.height}</div>
            <div>Transactions: ${block.tx_count}</div>
            <div>Total value: ${bsv} BSV</div>
            <div>Size: ${((block.size || 0) / 1024).toFixed(1)} KB</div>
            <div class="font-mono text-[10px] mt-1 text-neutral-400">${(block.hash || "").slice(0, 16)}...</div>
          `
          this.tooltip.style.left = event.clientX + 12 + "px"
          this.tooltip.style.top = event.clientY - 10 + "px"
          this.tooltip.classList.remove("hidden")
          return
        }
      }
    }

    if (this.instancedMesh && this.txGroup.visible) {
      const intersects = this.raycaster.intersectObject(this.instancedMesh)
      if (intersects.length > 0) {
        const instanceId = intersects[0].instanceId
        const node = Array.from(this.nodes.values()).find((n) => n._index === instanceId)

        if (node && this.tooltip) {
          const satoshis = node.total_out || 0
          const btc = (satoshis / 100_000_000).toFixed(8)
          const utxoLabel = node.spent
            ? '<span class="text-neutral-500">spent</span>'
            : '<span class="text-green-400">unspent (live UTXO)</span>'
          this.tooltip.innerHTML = `
            <div class="font-mono mb-1">${node.id.slice(0, 16)}...</div>
            <div>Block: ${node.block_height}</div>
            <div>Type: ${node.type} &middot; ${utxoLabel}</div>
            <div>Outputs: ${node.output_count} | Inputs: ${node.input_count}</div>
            <div>Value: ${btc} BSV</div>
          `
          this.tooltip.style.left = event.clientX + 12 + "px"
          this.tooltip.style.top = event.clientY - 10 + "px"
          this.tooltip.classList.remove("hidden")
          return
        }
      }
    }

    if (this.tooltip) this.tooltip.classList.add("hidden")
  },

  clearScene() {
    if (this.instancedMesh) {
      this.txGroup.remove(this.instancedMesh)
      this.instancedMesh.geometry.dispose()
      this.instancedMesh.material.dispose()
      this.instancedMesh = null
    }

    if (this.blockInstancedMesh) {
      this.blockGroup.remove(this.blockInstancedMesh)
      this.blockInstancedMesh.geometry.dispose()
      this.blockInstancedMesh.material.dispose()
      this.blockInstancedMesh = null
    }

    if (this.edgeLineSegments) {
      this.edgeGroup.remove(this.edgeLineSegments)
      this.edgeLineSegments.geometry.dispose()
      this.edgeLineSegments.material.dispose()
      this.edgeLineSegments = null
    }

    if (this.blockEdgeLineSegments) {
      this.blockEdgeGroup.remove(this.blockEdgeLineSegments)
      this.blockEdgeLineSegments.geometry.dispose()
      this.blockEdgeLineSegments.material.dispose()
      this.blockEdgeLineSegments = null
    }

    this.nodes.clear()
    this.edges = []
    this.blockData = []
    this.currentPositions = null
    this.targetPositions = null
    this.blockPositions = null
  },

  handlePlayback(data) {
    switch (data.action) {
      case "play":
        this.playbackState = "playing"
        this.playbackCursor = data.cursor || 0
        this.startPlayback()
        break
      case "pause":
        this.playbackState = "paused"
        this.stopPlaybackTimer()
        break
      case "rewind":
        this.playbackState = "stopped"
        this.playbackCursor = data.cursor || 0
        this.stopPlaybackTimer()
        this.revealBlocksUpTo(-1) // hide all
        break
      case "forward":
        this.playbackCursor = data.cursor || 0
        this.revealBlocksUpTo(this.playbackCursor)
        break
    }
  },

  startPlayback() {
    this.stopPlaybackTimer()

    const sortedBlocks = [...this.blockData].sort((a, b) => a.height - b.height)
    const maxHeight = sortedBlocks.length > 0
      ? sortedBlocks[sortedBlocks.length - 1].height
      : 0

    this.revealBlocksUpTo(this.playbackCursor)

    this.playbackTimer = setInterval(() => {
      if (this.playbackState !== "playing") {
        this.stopPlaybackTimer()
        return
      }

      this.playbackCursor++

      if (this.playbackCursor > maxHeight) {
        this.playbackState = "stopped"
        this.stopPlaybackTimer()
        this.pushEvent("playback_cursor_update", { cursor: maxHeight })
        return
      }

      this.revealBlocksUpTo(this.playbackCursor)
      this.pushEvent("playback_cursor_update", { cursor: this.playbackCursor })
    }, this.playbackSpeed)
  },

  stopPlaybackTimer() {
    if (this.playbackTimer) {
      clearInterval(this.playbackTimer)
      this.playbackTimer = null
    }
  },

  revealBlocksUpTo(maxHeight) {
    if (!this.blockInstancedMesh || this.blockData.length === 0) return

    const matrix = new THREE.Matrix4()
    const scaleMatrix = new THREE.Matrix4()
    const zeroMatrix = new THREE.Matrix4()
    zeroMatrix.makeScale(0, 0, 0)

    this.blockData.forEach((block) => {
      if (block.height <= maxHeight) {
        // Show this block at normal scale
        const pos = this.blockPositions ? this.blockPositions.get(block.height) : null
        if (pos) {
          const txCount = block.tx_count || 0
          const scale = 0.5 + Math.log2(Math.max(1, txCount)) * 0.3
          matrix.makeTranslation(pos.x, pos.y, pos.z)
          scaleMatrix.makeScale(scale, scale, scale)
          matrix.multiply(scaleMatrix)
          this.blockInstancedMesh.setMatrixAt(block._blockIndex, matrix)
        }
      } else {
        // Hide this block
        this.blockInstancedMesh.setMatrixAt(block._blockIndex, zeroMatrix)
      }
    })
    this.blockInstancedMesh.instanceMatrix.needsUpdate = true

    // Also show/hide transaction nodes by block height
    if (this.instancedMesh) {
      this.nodes.forEach((node) => {
        if (node.block_height <= maxHeight) {
          const pos = this.currentPositions ? this.currentPositions.get(node.id) : null
          if (pos) {
            const scale = node.type === "coinbase" ? 1.6 : 1.0
            matrix.makeTranslation(pos.x, pos.y, pos.z)
            scaleMatrix.makeScale(scale, scale, scale)
            matrix.multiply(scaleMatrix)
            this.instancedMesh.setMatrixAt(node._index, matrix)
          }
        } else {
          this.instancedMesh.setMatrixAt(node._index, zeroMatrix)
        }
      })
      this.instancedMesh.instanceMatrix.needsUpdate = true
    }
  },

  animate() {
    this.animationFrame = requestAnimationFrame(this.animate)

    // Handle layout transitions
    if (this.transitioning && this.startPositions && this.targetPositions) {
      const elapsed = performance.now() - this.transitionStart
      const t = Math.min(elapsed / LAYOUT.transitionDuration, 1.0)
      const eased = 1 - Math.pow(1 - t, 3)

      const interpolated = new Map()
      this.nodes.forEach((node) => {
        const start = this.startPositions.get(node.id)
        const target = this.targetPositions.get(node.id)
        if (start && target) {
          interpolated.set(node.id, new THREE.Vector3().lerpVectors(start, target, eased))
        }
      })

      this.applyPositions(interpolated)

      if (t >= 1.0) {
        this.transitioning = false
        this.currentPositions = this.targetPositions
      }
    }

    // Progressive disclosure: check zoom level each frame
    this.updateLOD()

    if (this.controls) this.controls.update()
    if (this.renderer && this.scene && this.camera) {
      this.renderer.render(this.scene, this.camera)
    }
  }
}
