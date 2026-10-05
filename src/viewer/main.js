import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { ASSETS, buildAsset, createMaterials } from '../assets/index.js';

const stage = document.getElementById('stage');
const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
stage.appendChild(renderer.domElement);

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x9cc3dc);
scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(), 0.04).texture;
scene.environmentIntensity = 0.9;

const camera = new THREE.PerspectiveCamera(40, 1, 0.01, 2000);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;

scene.add(new THREE.HemisphereLight(0xdfefff, 0x4a4030, 1.2));
const sun = new THREE.DirectionalLight(0xfff1dc, 2.6);
sun.castShadow = true;
sun.shadow.mapSize.set(2048, 2048);
sun.shadow.bias = -0.0004;
scene.add(sun, sun.target);

const floor = new THREE.Mesh(
  new THREE.CircleGeometry(4, 64).rotateX(-Math.PI / 2),
  new THREE.MeshStandardMaterial({ color: 0x5b6157, roughness: 1 }),
);
floor.receiveShadow = true;
scene.add(floor);

const mats = createMaterials();
const clock = new THREE.Clock();
let current = null;
let currentKey = null;
let mixer = null;
let equipped = null;

function setSun(radius) {
  sun.position.set(radius * 0.6, radius * 1.2, radius * 0.8);
  const cam = sun.shadow.camera;
  cam.left = cam.bottom = -radius;
  cam.right = cam.top = radius;
  cam.near = 0.1;
  cam.far = radius * 4;
  cam.updateProjectionMatrix();
}

function frame(object) {
  // Frame the map on its terrain; the sea plane is far larger than the island.
  const box = new THREE.Box3().setFromObject(object.getObjectByName('Terrain') ?? object);
  const size = box.getSize(new THREE.Vector3());
  const center = box.getCenter(new THREE.Vector3());
  const radius = Math.max(size.x, size.y, size.z);
  const isMap = ASSETS[currentKey].category === 'Map';
  floor.visible = !isMap;
  scene.fog = isMap ? new THREE.Fog(0x9cc3dc, 150, 450) : null;
  controls.target.copy(center);
  const dir = isMap ? new THREE.Vector3(0.6, 0.55, 0.9) : new THREE.Vector3(0.9, 0.35, 1.2);
  camera.position.copy(center).addScaledVector(dir.normalize(), radius * (isMap ? 0.8 : 1.5));
  camera.near = radius / 500;
  camera.far = radius * 20;
  camera.updateProjectionMatrix();
  setSun(isMap ? radius * 0.6 : Math.max(radius, 1));
  if (!isMap) floor.scale.setScalar(Math.max(radius, 0.3));
  floor.position.y = isMap ? 0 : box.min.y - 0.001;
}

function stats(object) {
  let meshes = 0, tris = 0;
  object.traverse((o) => {
    if (!o.isMesh) return;
    meshes++;
    tris += (o.geometry.index ? o.geometry.index.count : o.geometry.attributes.position.count) / 3;
  });
  const info = object.userData && Object.keys(object.userData).length
    ? '<br>' + Object.entries(object.userData).map(([k, v]) => `${k}: ${v}`).join('<br>')
    : '';
  document.getElementById('stats').innerHTML = `${meshes} meshes · ${Math.round(tris).toLocaleString()} triangles${info}`;
}

function show(key) {
  if (current) scene.remove(current);
  mixer = null;
  equipped = null;
  currentKey = key;
  current = buildAsset(key, mats);
  scene.add(current);
  if (ASSETS[key].category === 'Weapon') {
    // Lay guns flat, side-on, so they read clearly.
    current.rotation.y = Math.PI / 2;
  }
  frame(current);
  stats(current);
  document.querySelectorAll('#asset-list button').forEach((b) => b.classList.toggle('active', b.dataset.key === key));

  const tools = document.getElementById('character-tools');
  tools.hidden = !current.animations?.length;
  if (current.animations?.length) {
    mixer = new THREE.AnimationMixer(current);
    playClip('Idle');
    document.getElementById('equip').value = '';
  }
}

function playClip(name) {
  if (!mixer) return;
  mixer.stopAllAction();
  const clip = THREE.AnimationClip.findByName(current.animations, name);
  mixer.clipAction(clip).play();
  document.querySelectorAll('#anim-buttons button').forEach((b) => b.classList.toggle('active', b.textContent === name));
}

function equip(key) {
  const socket = current.getObjectByName('RightHandSocket');
  if (equipped) equipped.removeFromParent();
  equipped = key ? buildAsset(key, mats) : null;
  if (equipped) socket.add(equipped);
  playClip(equipped ? 'Aim' : 'Idle');
}

// Keep the equipped gun pointing where the character faces, whatever the hand does.
const worldQuat = new THREE.Quaternion();
function alignWeapon() {
  if (!equipped) return;
  const socket = equipped.parent;
  socket.updateWorldMatrix(true, false);
  socket.getWorldQuaternion(worldQuat);
  equipped.quaternion.copy(worldQuat.invert().multiply(current.quaternion));
}

// ---------------------------------------------------------------- UI

const list = document.getElementById('asset-list');
let lastCategory = null;
for (const [key, asset] of Object.entries(ASSETS)) {
  if (asset.category !== lastCategory) {
    const c = document.createElement('div');
    c.className = 'category';
    c.textContent = asset.category;
    list.appendChild(c);
    lastCategory = asset.category;
  }
  const b = document.createElement('button');
  b.textContent = asset.label;
  b.dataset.key = key;
  b.onclick = () => show(key);
  list.appendChild(b);
}

const animButtons = document.getElementById('anim-buttons');
for (const name of ['Idle', 'Walk', 'Run', 'Aim', 'WalkAim', 'RunAim', 'Skydive', 'Parachute']) {
  const b = document.createElement('button');
  b.textContent = name;
  b.onclick = () => playClip(name);
  animButtons.appendChild(b);
}

const equipSelect = document.getElementById('equip');
equipSelect.innerHTML = '<option value="">None</option>' + Object.entries(ASSETS)
  .filter(([, a]) => a.category === 'Weapon')
  .map(([k, a]) => `<option value="${k}">${a.label}</option>`).join('');
equipSelect.onchange = () => equip(equipSelect.value);

document.getElementById('download').onclick = async () => {
  const object = buildAsset(currentKey, mats);
  const glb = await new GLTFExporter().parseAsync(object, { binary: true, animations: object.animations ?? [] });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([glb], { type: 'model/gltf-binary' }));
  a.download = `${currentKey}.glb`;
  a.click();
  URL.revokeObjectURL(a.href);
};

function resize() {
  const { clientWidth: w, clientHeight: h } = stage;
  renderer.setSize(w, h);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
}
new ResizeObserver(resize).observe(stage);

renderer.setAnimationLoop(() => {
  const dt = clock.getDelta();
  mixer?.update(dt);
  alignWeapon();
  controls.update();
  renderer.render(scene, camera);
});

const initial = new URLSearchParams(location.search).get('asset');
show(ASSETS[initial] ? initial : 'soldier');
const initialWeapon = new URLSearchParams(location.search).get('equip');
if (initialWeapon && ASSETS[initialWeapon]) {
  equipSelect.value = initialWeapon;
  equip(initialWeapon);
}
const initialAnim = new URLSearchParams(location.search).get('anim');
if (initialAnim) playClip(initialAnim);
// Expose for debugging and automated screenshots.
window.workshop = { scene, camera, controls, show, equip, playClip };
