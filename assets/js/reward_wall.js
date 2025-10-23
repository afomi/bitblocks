import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';

const modeSelect = document.getElementById('reward-wall-mode');
const phaseSelect = document.getElementById('reward-wall-phase');
const loadedLabel = document.getElementById('reward-wall-loaded');
const rangeLabel = document.getElementById('reward-wall-range');
const statusLabel = document.getElementById('reward-wall-status');
const formatNumber = (value) => (typeof value === 'number' && Number.isFinite(value) ? value.toLocaleString() : '—');

let currentMode = modeSelect?.value || 'reward';
let currentPhase = phaseSelect?.value || '200k';

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x000000);

const camera = new THREE.PerspectiveCamera(
  70,
  window.innerWidth / window.innerHeight,
  0.1,
  5000
);
camera.position.set(0, 120, 280);

const renderer = new THREE.WebGLRenderer({
  canvas: document.getElementById('reward-wall-canvas'),
  antialias: true
});
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(window.devicePixelRatio);

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.05;

scene.add(new THREE.AmbientLight(0x404040, 2));

const directionalLight = new THREE.DirectionalLight(0xffffff, 2);
directionalLight.position.set(150, 150, 200);
scene.add(directionalLight);

let instancedMesh = null;
let modeLabel = 'reward';
let addressStats = null;
let rewardMetadata = null;

function clearCurrentMesh() {
  if (instancedMesh) {
    scene.remove(instancedMesh);
    instancedMesh.geometry.dispose();
    instancedMesh.material.dispose();
    instancedMesh = null;
  }
}

function createRewardMesh(rewardData) {
  clearCurrentMesh();

  if (!rewardData || rewardData.length === 0) {
    statusLabel.textContent = 'No reward data available.';
    loadedLabel.textContent = '0';
    return;
  }

  const geometry = new THREE.BoxGeometry(1, 1, 1);
  const material = new THREE.MeshPhongMaterial({
    color: 0x1f77b4,
    emissive: 0x001020,
    shininess: 40
  });

  instancedMesh = new THREE.InstancedMesh(geometry, material, rewardData.length);

  const spacing = 1.5;
  const midPoint = rewardData.length / 2;
  const matrix = new THREE.Matrix4();
  const color = new THREE.Color();

  const maxReward = rewardData.reduce((max, point) => Math.max(max, point.reward_btc), 0);
  const scaleMultiplier = maxReward === 0 ? 1 : 40 / maxReward;

  rewardData.forEach((point, index) => {
    const heightIndex = index - midPoint;
    const rewardScale = Math.max(point.reward_btc * scaleMultiplier, 0.1);

    matrix.compose(
      new THREE.Vector3(heightIndex * spacing, rewardScale / 2, 0),
      new THREE.Quaternion(),
      new THREE.Vector3(1, rewardScale, 1)
    );

    instancedMesh.setMatrixAt(index, matrix);

    const rewardRatio = maxReward === 0 ? 0 : point.reward_btc / maxReward;
    color.setHSL(0.55 - rewardRatio * 0.45, 0.9, 0.55);
    instancedMesh.setColorAt(index, color);
  });

  instancedMesh.instanceMatrix.needsUpdate = true;
  if (instancedMesh.instanceColor) {
    instancedMesh.instanceColor.needsUpdate = true;
  }

  scene.add(instancedMesh);

  loadedLabel.textContent = rewardData.length.toLocaleString();

  if (rewardMetadata) {
    rangeLabel.textContent = `${rewardMetadata.start_height.toLocaleString()} - ${rewardMetadata.end_height.toLocaleString()} (step ${rewardMetadata.step})`;
  }

  statusLabel.textContent = 'Reward schedule loaded.';
}

function createAddressMesh(topAddresses, metadata) {
  clearCurrentMesh();

  if (!topAddresses || topAddresses.length === 0) {
    loadedLabel.textContent = '0';
    statusLabel.textContent = metadata?.message || 'No address data available.';
    return;
  }

  const geometry = new THREE.BoxGeometry(1, 1, 1);
  const material = new THREE.MeshPhongMaterial({
    color: 0xff7f0e,
    emissive: 0x200800,
    shininess: 35
  });

  instancedMesh = new THREE.InstancedMesh(geometry, material, topAddresses.length);

  const spacing = 1.5;
  const midPoint = topAddresses.length / 2;
  const matrix = new THREE.Matrix4();
  const color = new THREE.Color();

  const maxValue = topAddresses.reduce((max, entry) => Math.max(max, entry.satoshis || 0), 0);
  const scaleMultiplier = maxValue === 0 ? 1 : 50 / (maxValue / 100_000_000);

  topAddresses.forEach((entry, index) => {
    const satoshis = entry.satoshis || 0;
    const btcValue = satoshis / 100_000_000;
    const heightScale = Math.max(btcValue * scaleMultiplier, 0.05);
    const columnIndex = index - midPoint;

    matrix.compose(
      new THREE.Vector3(columnIndex * spacing, heightScale / 2, 0),
      new THREE.Quaternion(),
      new THREE.Vector3(1, heightScale, 1)
    );

    instancedMesh.setMatrixAt(index, matrix);

    const ratio = maxValue === 0 ? 0 : satoshis / maxValue;
    color.setHSL(0.08 + ratio * 0.12, 0.9, 0.52);
    instancedMesh.setColorAt(index, color);
  });

  instancedMesh.instanceMatrix.needsUpdate = true;
  if (instancedMesh.instanceColor) {
    instancedMesh.instanceColor.needsUpdate = true;
  }

  scene.add(instancedMesh);

  loadedLabel.textContent = `${topAddresses.length.toLocaleString()} / ${formatNumber(metadata?.total_addresses)}`;
  rangeLabel.textContent = `${formatNumber(metadata?.start_height)} - ${formatNumber(metadata?.end_height)}`;

  if (metadata?.btc_supply) {
    const topShare = Number(topAddresses[0]?.percentage || 0).toFixed(2);
    statusLabel.textContent = `Top ${topAddresses.length} addresses hold ${topShare}% of ${metadata.btc_supply} BTC in this phase.`;
  } else {
    statusLabel.textContent = 'Address concentration loaded.';
  }

  renderTopAddressesList(topAddresses.slice(0, 10));
}

function renderTopAddressesList(entries) {
  const existingList = document.getElementById('reward-wall-top-addresses');
  if (!existingList) return;

  existingList.innerHTML = '';

  entries.forEach((entry) => {
    const row = document.createElement('div');
    row.className = 'grid grid-cols-[auto,1fr,auto,auto] gap-2 items-center text-xs text-zinc-300';
    const rank = Number(entry.rank || 0);
    const btc = Number(entry.btc ?? (entry.satoshis || 0) / 100_000_000);
    const percent = Number(entry.percentage || 0);
    row.innerHTML = `
      <span class="text-zinc-500 mr-2">#${rank}</span>
      <span class="truncate w-40">${entry.address}</span>
      <span class="ml-2">${btc.toFixed(4)} BTC</span>
      <span class="ml-2 text-zinc-500">(${percent.toFixed(3)}%)</span>
    `;
    existingList.appendChild(row);
  });
}

async function loadRewardData(phase) {
  statusLabel.textContent = 'Loading reward data…';

  try {
    const response = await fetch(`/reward_wall/reward_data?phase=${encodeURIComponent(phase)}`);

    if (!response.ok) {
      throw new Error(`Request failed with status ${response.status}`);
    }

    const payload = await response.json();
    rewardMetadata = payload.metadata;
    createRewardMesh(payload.data);
  } catch (error) {
    console.error('Failed to load reward data:', error);
    statusLabel.textContent = 'Failed to load reward data. See console for details.';
    clearCurrentMesh();
    loadedLabel.textContent = '0';
    rangeLabel.textContent = '—';
  }
}

async function loadAddressData(phase) {
  statusLabel.textContent = 'Loading address concentration…';
  clearCurrentMesh();
  renderTopAddressesList([]);
  loadedLabel.textContent = '0';
  rangeLabel.textContent = '—';

  try {
    const response = await fetch(`/reward_wall/address_data?phase=${encodeURIComponent(phase)}`);
    const payload = await response.json();

    const metadata = payload.metadata || {};
    addressStats = metadata;

    if (metadata.status === 'error') {
      statusLabel.textContent = metadata.message || 'Address concentration unavailable.';
      return;
    }

    const topAddresses = payload.top_addresses || [];

    if (topAddresses.length === 0) {
      statusLabel.textContent = metadata.message || 'No address data available yet.';
      return;
    }

    statusLabel.textContent = 'Rendering address concentration…';
    createAddressMesh(topAddresses, metadata);
  } catch (error) {
    console.error('Failed to load address concentration data:', error);
    statusLabel.textContent = 'Failed to load address concentration data.';
  }
}

function refreshVisualization() {
  if (currentMode === 'reward') {
    loadRewardData(currentPhase);
  } else {
    loadAddressData(currentPhase);
  }
}

modeSelect?.addEventListener('change', (event) => {
  currentMode = event.target.value;
  refreshVisualization();
});

phaseSelect?.addEventListener('change', (event) => {
  currentPhase = event.target.value;
  refreshVisualization();
});

let frames = 0;
setInterval(() => {
  statusLabel.dataset.fps = frames; // store for debugging if needed
  frames = 0;
}, 1000);

function animate() {
  requestAnimationFrame(animate);
  controls.update();
  renderer.render(scene, camera);
  frames++;
}

window.addEventListener('resize', () => {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
});

refreshVisualization();
animate();
