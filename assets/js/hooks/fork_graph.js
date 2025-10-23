import * as THREE from "three"
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js"

const STATUS_COLORS = {
  main: 0x22c55e,
  valid_fork: 0xf97316,
  fork: 0xf97316,
  valid_headers: 0x38bdf8,
  headers_only: 0xa855f7,
  invalid: 0xef4444,
  unknown: 0x94a3b8
}

const TIP_SCALE = 1.4
const NODE_SCALE = 1
const HEIGHT_SPACING = 2.8
const BRANCH_SPACING = 24
const DEPTH_SPACING = 6

function colorForStatus(status) {
  return STATUS_COLORS[status] || STATUS_COLORS.unknown
}

export default {
  mounted() {
    this.nodeMeshes = new Map()
    this.nodeData = new Map()
    this.edgeMeshes = new Map()
    this.tipHashes = new Set()
    this.branchOffsets = {}
    this.baseHeight = Number(this.el.dataset.baseHeight || 0)

    this.setupScene()
    this.animate = this.animate.bind(this)
    this.handleResize = this.handleResize.bind(this)

    window.addEventListener("resize", this.handleResize)
    requestAnimationFrame(this.animate)

    this.handleEvent("fork_snapshot", (data) => {
      this.applySnapshot(data)
    })

    this.handleEvent("fork_delta", (delta) => {
      this.applyDelta(delta)
    })
  },

  destroyed() {
    cancelAnimationFrame(this.animationFrame)
    window.removeEventListener("resize", this.handleResize)
    if (this.renderer) {
      this.renderer.dispose()
    }
  },

  setupScene() {
    const width = this.el.clientWidth || window.innerWidth
    const height = this.el.clientHeight || window.innerHeight

    this.scene = new THREE.Scene()
    this.scene.background = new THREE.Color(0x050608)

    this.camera = new THREE.PerspectiveCamera(60, width / height, 0.1, 10_000)
    this.camera.position.set(40, 80, 180)

    this.renderer = new THREE.WebGLRenderer({ antialias: true })
    this.renderer.setSize(width, height)
    this.renderer.setPixelRatio(window.devicePixelRatio || 1)
    this.el.replaceChildren(this.renderer.domElement)

    this.controls = new OrbitControls(this.camera, this.renderer.domElement)
    this.controls.enableDamping = true
    this.controls.dampingFactor = 0.08
    this.controls.maxDistance = 600
    this.controls.minDistance = 20

    const ambient = new THREE.AmbientLight(0xffffff, 0.6)
    this.scene.add(ambient)

    const directional = new THREE.DirectionalLight(0xffffff, 0.9)
    directional.position.set(80, 120, 160)
    this.scene.add(directional)

    this.nodeGroup = new THREE.Group()
    this.edgeGroup = new THREE.Group()
    this.scene.add(this.edgeGroup)
    this.scene.add(this.nodeGroup)

    this.edgeMaterial = new THREE.LineBasicMaterial({
      color: 0x64748b,
      transparent: true,
      opacity: 0.55
    })

    this.nodeGeometry = new THREE.SphereGeometry(1.4, 16, 16)
  },

  applySnapshot(data) {
    this.clearGraph()
    this.baseHeight = Number(data.base_height || this.baseHeight || 0)
    this.branchOffsets = data.branch_offsets || {}

    ;(data.nodes || []).forEach((node) => {
      this.addOrUpdateNode(node)
    })

    this.updateTips(data.tips || [])
    this.refreshAllEdges()
  },

  applyDelta(delta) {
    if (delta.base_height != null) {
      this.baseHeight = Number(delta.base_height)
    }

    if (delta.branch_offsets) {
      this.branchOffsets = delta.branch_offsets
    }

    ;(delta.nodes.removed || []).forEach(({ hash }) => {
      this.removeNode(hash)
    })

    ;(delta.nodes.updated || []).forEach((node) => {
      this.addOrUpdateNode(node)
    })

    ;(delta.nodes.added || []).forEach((node) => {
      this.addOrUpdateNode(node)
    })

    this.updateTips(delta.tips || [])
    this.refreshAllEdges()
  },

  addOrUpdateNode(node) {
    const existing = this.nodeMeshes.get(node.hash)
    this.nodeData.set(node.hash, node)

    if (existing) {
      existing.material.color.setHex(colorForStatus(node.status))
      existing.position.copy(this.positionFor(node))
      existing.material.needsUpdate = true
      this.ensureEdge(node.hash)
    } else {
      const material = new THREE.MeshStandardMaterial({
        color: colorForStatus(node.status),
        emissive: 0x0,
        metalness: 0.2,
        roughness: 0.6
      })

      const mesh = new THREE.Mesh(this.nodeGeometry.clone(), material)
      mesh.position.copy(this.positionFor(node))
      mesh.scale.setScalar(NODE_SCALE)
      mesh.userData.hash = node.hash

      this.nodeGroup.add(mesh)
      this.nodeMeshes.set(node.hash, mesh)
      this.ensureEdge(node.hash)
    }
  },

  removeNode(hash) {
    const mesh = this.nodeMeshes.get(hash)
    if (mesh) {
      this.nodeGroup.remove(mesh)
      if (mesh.geometry) mesh.geometry.dispose()
      if (mesh.material) mesh.material.dispose()
      this.nodeMeshes.delete(hash)
    }

    const line = this.edgeMeshes.get(hash)
    if (line) {
      this.edgeGroup.remove(line)
      if (line.geometry) line.geometry.dispose()
      this.edgeMeshes.delete(hash)
    }

    this.nodeData.delete(hash)
  },

  clearGraph() {
    this.nodeMeshes.forEach((mesh) => {
      this.nodeGroup.remove(mesh)
      if (mesh.geometry) mesh.geometry.dispose()
      if (mesh.material) mesh.material.dispose()
    })
    this.nodeMeshes.clear()
    this.nodeData.clear()

    this.edgeMeshes.forEach((line) => {
      this.edgeGroup.remove(line)
      if (line.geometry) line.geometry.dispose()
    })
    this.edgeMeshes.clear()
    this.tipHashes.clear()
  },

  ensureEdge(childHash) {
    const data = this.nodeData.get(childHash)
    if (!data || !data.parent) return

    const parentMesh = this.nodeMeshes.get(data.parent)
    const childMesh = this.nodeMeshes.get(childHash)
    if (!parentMesh || !childMesh) return

    const existing = this.edgeMeshes.get(childHash)
    const parentPos = parentMesh.position
    const childPos = childMesh.position

    if (existing) {
      const positions = existing.geometry.attributes.position.array
      positions[0] = parentPos.x
      positions[1] = parentPos.y
      positions[2] = parentPos.z
      positions[3] = childPos.x
      positions[4] = childPos.y
      positions[5] = childPos.z
      existing.geometry.attributes.position.needsUpdate = true
      existing.geometry.computeBoundingSphere()
    } else {
      const geometry = new THREE.BufferGeometry()
      const vertices = new Float32Array([
        parentPos.x,
        parentPos.y,
        parentPos.z,
        childPos.x,
        childPos.y,
        childPos.z
      ])
      geometry.setAttribute("position", new THREE.BufferAttribute(vertices, 3))
      const line = new THREE.Line(geometry, this.edgeMaterial)
      this.edgeGroup.add(line)
      this.edgeMeshes.set(childHash, line)
    }
  },

  refreshAllEdges() {
    this.edgeMeshes.forEach((line, hash) => {
      const node = this.nodeData.get(hash)
      if (!node) {
        this.edgeGroup.remove(line)
        if (line.geometry) line.geometry.dispose()
        this.edgeMeshes.delete(hash)
      }
    })

    this.nodeData.forEach((_node, hash) => this.ensureEdge(hash))
  },

  updateTips(tips) {
    this.tipHashes = new Set(tips.map((tip) => tip.hash))

    this.nodeMeshes.forEach((mesh, hash) => {
      const scale = this.tipHashes.has(hash) ? TIP_SCALE : NODE_SCALE
      mesh.scale.setScalar(scale)
    })
  },

  positionFor(node) {
    const base = this.baseHeight || 0
    const branchOffset = this.branchOffsets?.[node.branch_root] || 0

    const x = (Number(node.height || base) - base) * HEIGHT_SPACING
    const y = branchOffset * BRANCH_SPACING
    const z = -Number(node.branch_depth || 0) * DEPTH_SPACING

    return new THREE.Vector3(x, y, z)
  },

  handleResize() {
    if (!this.renderer || !this.camera) return
    const width = this.el.clientWidth || window.innerWidth
    const height = this.el.clientHeight || window.innerHeight
    this.camera.aspect = width / height
    this.camera.updateProjectionMatrix()
    this.renderer.setSize(width, height)
  },

  animate() {
    this.animationFrame = requestAnimationFrame(this.animate)
    if (this.controls) this.controls.update()
    if (this.renderer && this.scene && this.camera) {
      this.renderer.render(this.scene, this.camera)
    }
  }
}
