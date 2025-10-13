import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';

// Scene setup
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x000000);

const camera = new THREE.PerspectiveCamera(
  75,
  window.innerWidth / window.innerHeight,
  0.1,
  10000
);
camera.position.set(0, 100, 500);

const renderer = new THREE.WebGLRenderer({
  canvas: document.getElementById('wall-canvas'),
  antialias: true
});
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(window.devicePixelRatio);

// Controls
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.05;

// Lighting
const ambientLight = new THREE.AmbientLight(0x404040, 2);
scene.add(ambientLight);

const directionalLight = new THREE.DirectionalLight(0xffffff, 1);
directionalLight.position.set(100, 100, 100);
scene.add(directionalLight);

// Block visualization using instanced mesh for performance
let instancedMesh;
let totalBlocks = 0;
let loadedBlocks = 0;
const BLOCKS_PER_ROW = 100;
const BLOCK_SIZE = 1;
const BLOCK_SPACING = 1.2;

// Create geometry and material once
const geometry = new THREE.BoxGeometry(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE);
const material = new THREE.MeshPhongMaterial({
  color: 0x00ff00,
  emissive: 0x001100,
  shininess: 30
});

// Load blocks data
async function loadBlocks(offset = 0, limit = 10000) {
  try {
    const response = await fetch(`/wall/blocks_data?offset=${offset}&limit=${limit}`);
    const data = await response.json();

    if (offset === 0) {
      totalBlocks = data.total;
      document.getElementById('total-blocks').textContent = totalBlocks.toLocaleString();

      // Initialize instanced mesh with total capacity
      // For performance, we'll use instanced rendering
      const maxInstances = Math.min(totalBlocks, 100000); // Cap at 100k for performance
      instancedMesh = new THREE.InstancedMesh(geometry, material, maxInstances);
      scene.add(instancedMesh);
    }

    // Position each block
    data.blocks.forEach((block, idx) => {
      const globalIdx = offset + idx;
      if (globalIdx >= instancedMesh.count) return;

      const row = Math.floor(globalIdx / BLOCKS_PER_ROW);
      const col = globalIdx % BLOCKS_PER_ROW;

      const matrix = new THREE.Matrix4();
      matrix.setPosition(
        (col - BLOCKS_PER_ROW / 2) * BLOCK_SPACING,
        0,
        (row - BLOCKS_PER_ROW / 2) * BLOCK_SPACING
      );

      // Color based on transaction count (green = few, red = many)
      const txRatio = Math.min(block.num_tx / 5000, 1);
      const color = new THREE.Color();
      color.setHSL(0.33 * (1 - txRatio), 1, 0.5); // Green to red
      instancedMesh.setColorAt(globalIdx, color);

      instancedMesh.setMatrixAt(globalIdx, matrix);
      loadedBlocks++;
    });

    instancedMesh.instanceMatrix.needsUpdate = true;
    if (instancedMesh.instanceColor) {
      instancedMesh.instanceColor.needsUpdate = true;
    }

    document.getElementById('loaded-blocks').textContent = loadedBlocks.toLocaleString();

    // Load next batch if there are more blocks
    if (offset + limit < Math.min(totalBlocks, 100000)) {
      setTimeout(() => loadBlocks(offset + limit, limit), 100);
    }

  } catch (error) {
    console.error('Failed to load blocks:', error);
  }
}

// FPS counter
let frames = 0;
setInterval(() => {
  document.getElementById('fps').textContent = frames;
  frames = 0;
}, 1000);

// Animation loop
function animate() {
  requestAnimationFrame(animate);

  controls.update();
  renderer.render(scene, camera);

  frames++;
}

// Handle window resize
window.addEventListener('resize', () => {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
});

// Start
loadBlocks();
animate();
