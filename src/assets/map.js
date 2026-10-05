import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';

// "Training Island": a 240 m x 240 m map with rolling terrain, a small town on
// a flat plateau, a road, a warehouse, a watchtower, forest, rocks and cover.
// Everything is generated from a fixed seed, so the map is identical on every
// build. getHeight(x, z) gives the ground height for placing the player.

export const MAP_SIZE = 240;
export const SEA_LEVEL = 0;
const TOWN = { x: 10, z: -5, radius: 42, height: 4 };
const ROAD_Z = -5;

function mulberry32(seed) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function valueNoise(seed) {
  const rnd = mulberry32(seed);
  const perm = new Float32Array(256 * 256).map(() => rnd());
  const at = (x, z) => perm[((x & 255) << 8) | (z & 255)];
  const fade = (t) => t * t * (3 - 2 * t);
  return (x, z) => {
    const xi = Math.floor(x), zi = Math.floor(z);
    const xf = fade(x - xi), zf = fade(z - zi);
    const a = at(xi, zi), b = at(xi + 1, zi), c = at(xi, zi + 1), d = at(xi + 1, zi + 1);
    return a + (b - a) * xf + (c - a) * zf + (a - b - c + d) * xf * zf;
  };
}

const noise = valueNoise(1337);
function fbm(x, z) {
  let sum = 0, amp = 1, freq = 1, norm = 0;
  for (let o = 0; o < 4; o++) {
    sum += amp * noise(x * freq, z * freq);
    norm += amp;
    amp *= 0.5;
    freq *= 2.03;
  }
  return sum / norm;
}

const smoothstep = (a, b, x) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

export function getHeight(x, z) {
  // Island falloff toward the edges.
  const d = Math.hypot(x, z) / (MAP_SIZE / 2);
  const island = 1 - smoothstep(0.62, 0.98, d);
  let h = 3 + fbm(x * 0.018 + 50, z * 0.018 + 50) * 14 - 4;
  // A hill in the north-east for the watchtower.
  h += 10 * Math.exp(-((x - 60) ** 2 + (z + 60) ** 2) / 900);
  h = h * island - 3 * (1 - island);
  // Flat town plateau.
  const t = smoothstep(TOWN.radius, TOWN.radius - 12, Math.hypot(x - TOWN.x, z - TOWN.z));
  h = h * (1 - t) + TOWN.height * t;
  // Road is graded smooth.
  const r = smoothstep(7, 3.5, Math.abs(z - ROAD_Z)) * smoothstep(0.85, 0.7, d);
  const roadH = Math.max(TOWN.height, 0.5 * h + 2);
  h = h * (1 - r) + roadH * r;
  return h;
}

// ---------------------------------------------------------------- helpers

function named(obj, name) {
  obj.name = name;
  return obj;
}

function shadowed(m) {
  m.castShadow = true;
  m.receiveShadow = true;
  return m;
}

// Collects transformed geometries per material and merges them, so forests
// and rocks become a handful of meshes instead of hundreds of nodes.
class Batcher {
  constructor() { this.buckets = new Map(); }
  push(material, geometry, matrix) {
    const g = geometry.index ? geometry.toNonIndexed() : geometry.clone();
    g.applyMatrix4(matrix);
    for (const key of Object.keys(g.attributes)) {
      if (key !== 'position' && key !== 'normal') g.deleteAttribute(key);
    }
    if (!this.buckets.has(material)) this.buckets.set(material, []);
    this.buckets.get(material).push(g);
  }
  build(name) {
    const group = named(new THREE.Group(), name);
    for (const [material, geos] of this.buckets) {
      const mesh = shadowed(new THREE.Mesh(mergeGeometries(geos), material));
      mesh.name = `${name}_${material.name}`;
      group.add(mesh);
    }
    return group;
  }
}

// Merges all meshes under a building/prop group into one mesh per material,
// keeping the group (name, transform, userData) so the game can still find it.
// Small or walk-through parts that should not block the player.
const NO_COLLIDE = /^(Door|Rung|LadderSide|Brace|Edge|Band|Sill|Flare|Rib|Gable|Ceiling)/;

function flatten(group) {
  group.updateMatrixWorld(true);
  const inverse = group.matrixWorld.clone().invert();
  const batch = new Batcher();
  // Box colliders in the group's local space, read later by collectColliders().
  group.colliderBoxes = group.colliderBoxes ?? [];
  group.traverse((o) => {
    if (!o.isMesh) return;
    const local = inverse.clone().multiply(o.matrixWorld);
    batch.push(o.material, o.geometry, local);
    if (o.geometry.type === 'BoxGeometry' && !NO_COLLIDE.test(o.name)) {
      const { width, height, depth } = o.geometry.parameters;
      group.colliderBoxes.push({ matrix: local, size: [width, height, depth] });
    }
  });
  const merged = batch.build(group.name);
  group.clear();
  for (const child of [...merged.children]) group.add(child);
  return group;
}

const tmpMatrix = (x, y, z, ry = 0, sx = 1, sy = sx, sz = sx) =>
  new THREE.Matrix4().compose(
    new THREE.Vector3(x, y, z),
    new THREE.Quaternion().setFromEuler(new THREE.Euler(0, ry, 0)),
    new THREE.Vector3(sx, sy, sz),
  );

// ---------------------------------------------------------------- terrain

function buildTerrain(mats) {
  const seg = 160;
  const geo = new THREE.PlaneGeometry(MAP_SIZE, MAP_SIZE, seg, seg);
  geo.rotateX(-Math.PI / 2);
  const pos = geo.attributes.position;
  for (let i = 0; i < pos.count; i++) {
    pos.setY(i, getHeight(pos.getX(i), pos.getZ(i)));
  }
  geo.computeVertexNormals();

  const colors = new Float32Array(pos.count * 3);
  const c = new THREE.Color();
  const grass = new THREE.Color(0x5d7a3a), grass2 = new THREE.Color(0x7a8f45);
  const dirt = new THREE.Color(0x7d6a4a), sand = new THREE.Color(0xcbb98a), rock = new THREE.Color(0x77736b);
  const nrm = geo.attributes.normal;
  for (let i = 0; i < pos.count; i++) {
    const x = pos.getX(i), y = pos.getY(i), z = pos.getZ(i);
    const n = noise(x * 0.15, z * 0.15);
    c.copy(grass).lerp(grass2, n);
    const town = smoothstep(TOWN.radius - 6, TOWN.radius - 16, Math.hypot(x - TOWN.x, z - TOWN.z));
    c.lerp(dirt, town * 0.55 * (0.6 + 0.4 * n));
    c.lerp(rock, smoothstep(0.85, 0.7, nrm.getY(i)));
    c.lerp(sand, smoothstep(1.6, 0.4, y));
    colors.set([c.r, c.g, c.b], i * 3);
  }
  geo.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  const mesh = new THREE.Mesh(geo, mats.terrain);
  mesh.name = 'Terrain';
  mesh.receiveShadow = true;
  return mesh;
}

function buildWater(mats) {
  const geo = new THREE.PlaneGeometry(MAP_SIZE * 2.5, MAP_SIZE * 2.5);
  geo.rotateX(-Math.PI / 2);
  const m = new THREE.Mesh(geo, mats.water);
  m.name = 'Water';
  m.position.y = SEA_LEVEL;
  return m;
}

function buildRoad(mats) {
  const group = named(new THREE.Group(), 'Road');
  const half = MAP_SIZE * 0.4;
  const seg = 120;
  const geo = new THREE.PlaneGeometry(half * 2, 6, seg, 1);
  geo.rotateX(-Math.PI / 2);
  const pos = geo.attributes.position;
  for (let i = 0; i < pos.count; i++) {
    const x = pos.getX(i), z = pos.getZ(i) + ROAD_Z;
    pos.setZ(i, z);
    pos.setY(i, getHeight(x, z) + 0.04);
  }
  geo.computeVertexNormals();
  const road = new THREE.Mesh(geo, mats.asphalt);
  road.name = 'Asphalt';
  road.receiveShadow = true;
  group.add(road);

  const dashes = [];
  for (let x = -half + 2; x < half - 2; x += 6) {
    const d = new THREE.PlaneGeometry(2.5, 0.15);
    d.rotateX(-Math.PI / 2);
    d.translate(x, getHeight(x, ROAD_Z) + 0.06, ROAD_Z);
    dashes.push(d);
  }
  const lines = new THREE.Mesh(mergeGeometries(dashes), mats.roadLine);
  lines.name = 'RoadLines';
  lines.receiveShadow = true;
  group.add(lines);
  return group;
}

// ---------------------------------------------------------------- buildings

function boxMesh(name, w, h, d, material, x, y, z) {
  const m = shadowed(new THREE.Mesh(new THREE.BoxGeometry(w, h, d), material));
  m.name = name;
  m.position.set(x, y, z);
  return m;
}

// Wall along X with optional openings: [{ x, w, y0, y1, glass }]
function wall(name, length, height, thickness, material, openings, mats) {
  const group = named(new THREE.Group(), name);
  const cuts = [...openings].sort((a, b) => a.x - b.x);
  let cursor = -length / 2;
  for (const o of cuts) {
    const left = o.x - o.w / 2, right = o.x + o.w / 2;
    if (left > cursor) {
      group.add(boxMesh('WallPart', left - cursor, height, thickness, material, (cursor + left) / 2, height / 2, 0));
    }
    if (o.y0 > 0) group.add(boxMesh('WallBelow', o.w, o.y0, thickness, material, o.x, o.y0 / 2, 0));
    group.add(boxMesh('WallAbove', o.w, height - o.y1, thickness, material, o.x, (height + o.y1) / 2, 0));
    if (o.glass) {
      const glass = boxMesh('Window', o.w, o.y1 - o.y0, 0.04, mats.windowGlass, o.x, (o.y0 + o.y1) / 2, 0);
      glass.castShadow = false;
      group.add(glass);
      group.add(boxMesh('Sill', o.w + 0.2, 0.08, thickness + 0.15, mats.concrete, o.x, o.y0 - 0.04, 0));
    }
    cursor = right;
  }
  if (cursor < length / 2) {
    group.add(boxMesh('WallPart', length / 2 - cursor, height, thickness, material, (cursor + length / 2) / 2, height / 2, 0));
  }
  return group;
}

function gableRoof(name, w, d, rise, overhang, material) {
  const shape = new THREE.Shape();
  const hw = w / 2 + overhang;
  shape.moveTo(-hw, 0);
  shape.lineTo(0, rise);
  shape.lineTo(hw, 0);
  shape.lineTo(hw, -0.15);
  shape.lineTo(0, rise - 0.15);
  shape.lineTo(-hw, -0.15);
  shape.closePath();
  const geo = new THREE.ExtrudeGeometry(shape, { depth: d + overhang * 2, bevelEnabled: false });
  geo.translate(0, 0, -(d + overhang * 2) / 2);
  const m = shadowed(new THREE.Mesh(geo, material));
  m.name = name;
  return m;
}

function gableEnd(name, w, rise, material) {
  const shape = new THREE.Shape();
  shape.moveTo(-w / 2, 0);
  shape.lineTo(0, rise);
  shape.lineTo(w / 2, 0);
  shape.closePath();
  const geo = new THREE.ExtrudeGeometry(shape, { depth: 0.25, bevelEnabled: false });
  geo.translate(0, 0, -0.125);
  const m = shadowed(new THREE.Mesh(geo, material));
  m.name = name;
  return m;
}

// Enterable house with a door, windows, floors and a gable roof.
function house(mats, name, w, d, floors, wallMat = mats.wallPlaster) {
  const g = named(new THREE.Group(), name);
  const fh = 3, t = 0.25, totalH = fh * floors;
  g.add(boxMesh('Foundation', w + 0.4, 0.4, d + 0.4, mats.concrete, 0, -0.1, 0));
  for (let f = 0; f < floors; f++) {
    const y = f * fh;
    const windowsX = [];
    for (let x = -w / 2 + 1.5; x <= w / 2 - 1.5; x += 2.5) windowsX.push(x);
    const front = f === 0
      ? [{ x: 0, w: 1.1, y0: 0, y1: 2.2 }, ...windowsX.filter((x) => Math.abs(x) > 1.4).map((x) => ({ x, w: 1.1, y0: 1, y1: 2.2, glass: true }))]
      : windowsX.map((x) => ({ x, w: 1.1, y0: 1, y1: 2.2, glass: true }));
    const back = windowsX.map((x) => ({ x, w: 1.1, y0: 1, y1: 2.2, glass: true }));
    const side = [{ x: 0, w: 1.1, y0: 1, y1: 2.2, glass: true }];

    const wf = wall('FrontWall', w, fh, t, wallMat, front, mats);
    wf.position.set(0, y, d / 2 - t / 2);
    const wb = wall('BackWall', w, fh, t, wallMat, back, mats);
    wb.position.set(0, y, -d / 2 + t / 2);
    const wl = wall('LeftWall', d - 2 * t, fh, t, wallMat, side, mats);
    wl.rotation.y = Math.PI / 2;
    wl.position.set(-w / 2 + t / 2, y, 0);
    const wr = wall('RightWall', d - 2 * t, fh, t, wallMat, side, mats);
    wr.rotation.y = Math.PI / 2;
    wr.position.set(w / 2 - t / 2, y, 0);
    g.add(wf, wb, wl, wr);
    g.add(boxMesh(`Floor${f}`, w - 2 * t, 0.2, d - 2 * t, mats.concrete, 0, y + 0.1, 0));
  }
  g.add(boxMesh('Ceiling', w, 0.2, d, mats.concrete, 0, totalH + 0.1, 0));
  const rise = Math.min(w, d) * 0.3;
  const roof = gableRoof('Roof', w, d, rise, 0.4, mats.roofTile);
  roof.position.y = totalH + 0.2;
  g.add(roof);
  for (const s of [-1, 1]) {
    const end = gableEnd('Gable', w, rise, wallMat);
    end.position.set(0, totalH + 0.2, s * (d / 2 - 0.125));
    g.add(end);
  }
  // Door panel swung open + steps
  const door = boxMesh('Door', 1.05, 2.15, 0.06, mats.door, -0.5, 1.08, d / 2 + 0.5);
  door.rotation.y = -Math.PI / 2.3;
  g.add(door);
  g.add(boxMesh('Step', 1.6, 0.2, 0.6, mats.concrete, 0, 0.0, d / 2 + 0.4));
  if (floors > 1) {
    // Interior stairs along the left wall.
    for (let i = 0; i < 12; i++) {
      g.add(boxMesh('Stair', 1, 0.25, 0.3, mats.concrete, -w / 2 + 0.85, 0.125 + i * 0.25, d / 2 - 1 - i * 0.3));
    }
  }
  g.userData = { type: 'building', floors };
  return g;
}

function warehouse(mats) {
  const g = named(new THREE.Group(), 'Warehouse');
  const w = 18, d = 12, h = 6;
  g.add(boxMesh('Slab', w + 1, 0.3, d + 1, mats.concrete, 0, -0.05, 0));
  const front = wall('FrontWall', w, h, 0.2, mats.metalSheet, [{ x: -3, w: 5, y0: 0, y1: 4.5 }, { x: 5, w: 1.2, y0: 0, y1: 2.2 }], mats);
  front.position.z = d / 2;
  const back = wall('BackWall', w, h, 0.2, mats.metalSheet, [{ x: 0, w: 5, y0: 0, y1: 4.5 }], mats);
  back.position.z = -d / 2;
  const left = wall('LeftWall', d, h, 0.2, mats.metalSheet, [{ x: 0, w: 3, y0: 3.5, y1: 4.8, glass: true }], mats);
  left.rotation.y = Math.PI / 2;
  left.position.x = -w / 2;
  const right = left.clone();
  right.name = 'RightWall';
  right.position.x = w / 2;
  g.add(front, back, left, right);
  // Corrugation ribs on the outside of the side walls.
  for (let x = -w / 2 + 0.5; x < w / 2; x += 1) {
    for (const s of [-1, 1]) {
      if (s > 0 && x > -5.6 && x < -0.4) continue;
      if (s > 0 && x > 4.3 && x < 5.7) continue;
      if (s < 0 && Math.abs(x) < 2.6) continue;
      g.add(boxMesh('Rib', 0.08, h, 0.06, mats.metalSheet, x, h / 2, s * (d / 2 + 0.12)));
    }
  }
  const roof = gableRoof('Roof', d, w, 1.5, 0.3, mats.metalSheet);
  roof.rotation.y = Math.PI / 2;
  roof.position.y = h;
  g.add(roof);
  // Interior: shelves and crates for cover.
  for (let i = 0; i < 3; i++) {
    g.add(boxMesh('Shelf', 6, 2.4, 1.2, mats.metalSheet, 2, 1.2, -3.5 + i * 3.2));
  }
  g.add(boxMesh('Container', 6, 2.6, 2.4, mats.airdrop, -5.5, 1.3, -3.2));
  g.userData = { type: 'building' };
  return g;
}

function watchtower(mats) {
  const g = named(new THREE.Group(), 'Watchtower');
  const h = 9;
  for (const [x, z] of [[-1.5, -1.5], [1.5, -1.5], [-1.5, 1.5], [1.5, 1.5]]) {
    const leg = boxMesh('Leg', 0.25, h, 0.25, mats.bark, x * 1.1, h / 2, z * 1.1);
    g.add(leg);
  }
  for (let y = 2; y < h; y += 2.5) {
    for (const s of [-1, 1]) {
      g.add(boxMesh('Brace', 3.4, 0.12, 0.12, mats.bark, 0, y, s * 1.65));
      g.add(boxMesh('Brace', 0.12, 0.12, 3.4, mats.bark, s * 1.65, y, 0));
    }
  }
  g.add(boxMesh('Platform', 4.2, 0.2, 4.2, mats.crateWood, 0, h, 0));
  for (const s of [-1, 1]) {
    g.add(boxMesh('Rail', 4.2, 1.1, 0.1, mats.crateWood, 0, h + 0.65, s * 2.05));
    g.add(boxMesh('Rail', 0.1, 1.1, 4.2, mats.crateWood, s * 2.05, h + 0.65, 0));
  }
  for (const [x, z] of [[-2, -2], [2, -2], [-2, 2], [2, 2]]) {
    g.add(boxMesh('Post', 0.15, 2.4, 0.15, mats.bark, x, h + 1.2, z));
  }
  const roof = new THREE.Mesh(new THREE.ConeGeometry(3.4, 1.4, 4), mats.roofTile);
  roof.name = 'Roof';
  roof.rotation.y = Math.PI / 4;
  roof.position.y = h + 3.1;
  g.add(shadowed(roof));
  // Ladder
  for (let y = 0.4; y < h; y += 0.4) g.add(boxMesh('Rung', 0.6, 0.06, 0.06, mats.bark, 0, y, 2.25));
  for (const s of [-1, 1]) g.add(boxMesh('LadderSide', 0.08, h, 0.08, mats.bark, s * 0.32, h / 2, 2.25));
  g.userData = { type: 'tower' };
  return g;
}

// ---------------------------------------------------------------- props

function crate(mats, name, size = 1.2) {
  const g = named(new THREE.Group(), name);
  g.add(boxMesh('Box', size, size, size, mats.crateWood, 0, size / 2, 0));
  const e = 0.08;
  for (const sx of [-1, 1]) for (const sz of [-1, 1]) {
    g.add(boxMesh('Edge', e, size + 0.02, e, mats.bark, sx * (size / 2), size / 2, sz * (size / 2)));
  }
  for (const sy of [0, 1]) {
    g.add(boxMesh('Band', size + 0.04, e, size + 0.04, mats.bark, 0, sy * size, 0));
  }
  g.userData = { type: 'cover' };
  return g;
}

function sandbagWall(mats, name, length = 4) {
  const g = named(new THREE.Group(), name);
  const bag = new THREE.CapsuleGeometry(0.17, 0.45, 4, 10);
  bag.rotateZ(Math.PI / 2);
  bag.scale(1, 0.7, 1);
  const geos = [];
  for (let row = 0; row < 3; row++) {
    const off = row % 2 ? 0.35 : 0;
    for (let x = -length / 2 + 0.4 + off; x <= length / 2 - 0.3; x += 0.75) {
      const b = bag.clone();
      b.translate(x, 0.12 + row * 0.23, 0);
      geos.push(b);
    }
  }
  const m = shadowed(new THREE.Mesh(mergeGeometries(geos), mats.sandbag));
  m.name = 'Bags';
  g.add(m);
  g.colliderBoxes = [{ matrix: new THREE.Matrix4().makeTranslation(0, 0.35, 0), size: [length - 0.2, 0.7, 0.4] }];
  g.userData = { type: 'cover' };
  return g;
}

function airdrop(mats) {
  const g = named(new THREE.Group(), 'Airdrop');
  g.add(boxMesh('Crate', 1.4, 1.1, 1.4, mats.airdrop, 0, 0.55, 0));
  for (const s of [-1, 1]) {
    g.add(boxMesh('Stripe', 1.42, 0.18, 0.2, mats.airdropStripe, 0, 0.55, s * 0.45));
  }
  g.add(boxMesh('Pallet', 1.6, 0.15, 1.6, mats.crateWood, 0, 0.0, 0));
  // Smoke flare canister
  g.add(boxMesh('Flare', 0.1, 0.3, 0.1, mats.redDot, 0.5, 1.25, 0.5));
  g.userData = { type: 'airdrop' };
  return g;
}

// Trunks and rocks block movement as vertical cylinders: [x, z, radius].
let circleColliders = [];

function deciduousTree(batch, mats, x, y, z, s, rnd) {
  circleColliders.push([x, z, 0.3 * s]);
  const trunk = new THREE.CylinderGeometry(0.18, 0.3, 4, 7);
  trunk.translate(0, 2, 0);
  batch.push(mats.bark, trunk, tmpMatrix(x, y, z, rnd() * 6, s));
  const crown = new THREE.IcosahedronGeometry(1.8, 1);
  for (let i = 0; i < 3; i++) {
    const ox = (rnd() - 0.5) * 1.6, oz = (rnd() - 0.5) * 1.6, oy = 4.2 + rnd() * 1.4;
    const k = 0.8 + rnd() * 0.5;
    batch.push(mats.leaves, crown, tmpMatrix(x + ox * s, y + oy * s, z + oz * s, rnd() * 6, s * k, s * k * 0.85, s * k));
  }
}

function pineTree(batch, mats, x, y, z, s, rnd) {
  circleColliders.push([x, z, 0.25 * s]);
  const trunk = new THREE.CylinderGeometry(0.12, 0.25, 3, 6);
  trunk.translate(0, 1.5, 0);
  batch.push(mats.bark, trunk, tmpMatrix(x, y, z, 0, s));
  for (let i = 0; i < 4; i++) {
    const cone = new THREE.ConeGeometry(2.2 - i * 0.45, 2.4, 8);
    cone.translate(0, 2.6 + i * 1.3, 0);
    batch.push(mats.pineLeaves, cone, tmpMatrix(x, y, z, rnd() * 6, s));
  }
}

function rockGeometry(rnd) {
  const geo = new THREE.DodecahedronGeometry(1, 1);
  const p = geo.attributes.position;
  const a = rnd() * 10, b = rnd() * 10;
  for (let i = 0; i < p.count; i++) {
    // Offset depends only on the vertex position, so duplicated corners of
    // this non-indexed geometry move together and the surface stays closed.
    const x = p.getX(i), y = p.getY(i), z = p.getZ(i);
    const k = 0.8 + 0.2 * Math.sin(x * 3.1 + a) * Math.cos(z * 2.7 + y * 1.9 + b);
    p.setXYZ(i, p.getX(i) * k, p.getY(i) * k * 0.7, p.getZ(i) * k);
  }
  geo.computeVertexNormals();
  return geo;
}

// ---------------------------------------------------------------- map

export function createMap(mats) {
  const rnd = mulberry32(42);
  circleColliders = [];
  const map = named(new THREE.Group(), 'TrainingIsland');
  map.add(buildTerrain(mats));
  map.add(buildWater(mats));
  map.add(buildRoad(mats));

  const placeOnGround = (obj, x, z, ry = 0) => {
    obj.position.set(x, getHeight(x, z), z);
    obj.rotation.y = ry;
    return obj;
  };

  // Town: houses on both sides of the road.
  const town = named(new THREE.Group(), 'Town');
  const houses = [
    ['House_A', -12, 10, 10, 8, 2, Math.PI],
    ['House_B', 4, 11, 8, 7, 1, Math.PI],
    ['House_C', 18, 12, 9, 8, 2, Math.PI],
    ['House_D', -10, -20, 9, 8, 1, 0],
    ['House_E', 6, -21, 11, 8, 2, 0],
    ['House_F', 24, -19, 8, 7, 1, 0],
  ];
  for (const [name, x, z, w, d, floors, ry] of houses) {
    const wallMat = floors > 1 ? mats.wallPlaster : mats.concrete;
    town.add(placeOnGround(flatten(house(mats, name, w, d, floors, wallMat)), x + TOWN.x, z + TOWN.z, ry));
  }
  town.add(placeOnGround(flatten(warehouse(mats)), TOWN.x + 38, TOWN.z + 16, Math.PI));
  map.add(town);

  map.add(placeOnGround(flatten(watchtower(mats)), 60, -60));

  // Cover around town and the tower.
  const props = named(new THREE.Group(), 'Props');
  const crateSpots = [[-4, 2], [-3, 3.3], [30, 3], [31.2, 4.4], [12, -12], [-22, -2], [52, -54], [64, -66]];
  crateSpots.forEach(([x, z], i) => {
    props.add(placeOnGround(flatten(crate(mats, `Crate${i}`, i % 3 ? 1.2 : 0.9)), x + TOWN.x * (i < 6 ? 1 : 0), z + TOWN.z * (i < 6 ? 1 : 0), rnd() * 0.6));
  });
  const bagSpots = [[-30, -5, Math.PI / 2], [48, -5, Math.PI / 2], [55, -52, 0.4], [66, -68, -0.6], [-5, 22, 0]];
  bagSpots.forEach(([x, z, ry], i) => props.add(placeOnGround(sandbagWall(mats, `Sandbags${i}`), x + (i < 2 ? TOWN.x : 0), z + (i < 2 ? TOWN.z : 0), ry)));
  props.add(placeOnGround(flatten(airdrop(mats)), -45, 40, 0.3));
  map.add(props);

  // Vegetation and rocks, merged per material.
  const nature = new Batcher();
  const rocks = Array.from({ length: 4 }, () => rockGeometry(rnd));
  let trees = 0, attempts = 0;
  while (trees < 220 && attempts < 5000) {
    attempts++;
    const x = (rnd() - 0.5) * MAP_SIZE * 0.85;
    const z = (rnd() - 0.5) * MAP_SIZE * 0.85;
    const y = getHeight(x, z);
    if (y < 1.5) continue;
    if (Math.hypot(x - TOWN.x, z - TOWN.z) < TOWN.radius + 4) continue;
    if (Math.abs(z - ROAD_Z) < 7) continue;
    if (Math.hypot(x - 60, z + 60) < 10 || Math.hypot(x + 45, z - 40) < 6) continue;
    const s = 0.8 + rnd() * 0.6;
    if (y > 9 || rnd() < 0.35) pineTree(nature, mats, x, y - 0.1, z, s, rnd);
    else deciduousTree(nature, mats, x, y - 0.1, z, s, rnd);
    trees++;
  }
  for (let i = 0; i < 70; i++) {
    const x = (rnd() - 0.5) * MAP_SIZE * 0.9;
    const z = (rnd() - 0.5) * MAP_SIZE * 0.9;
    const y = getHeight(x, z);
    if (y < 0.3 || Math.hypot(x - TOWN.x, z - TOWN.z) < TOWN.radius - 4 || Math.abs(z - ROAD_Z) < 5) continue;
    const s = 0.5 + rnd() * 1.8;
    nature.push(mats.rock, rocks[i % rocks.length], tmpMatrix(x, y + s * 0.15, z, rnd() * 6, s));
    if (s > 0.9) circleColliders.push([x, z, s * 0.8]);
  }
  map.add(nature.build('Nature'));

  // Spawn points for players / bots (empty nodes, read by the game).
  const spawns = named(new THREE.Group(), 'SpawnPoints');
  [[TOWN.x, TOWN.z], [-60, 30], [70, 40], [-50, -60], [60, -45], [0, 70], [-80, -10], [85, -5]].forEach(([x, z], i) => {
    const s = named(new THREE.Group(), `Spawn${i}`);
    s.position.set(x, getHeight(x, z), z);
    spawns.add(s);
  });
  map.add(spawns);

  map.userData = { size: MAP_SIZE, seaLevel: SEA_LEVEL };
  map.collision = collectCollision(map);
  return map;
}

// ---------------------------------------------------------------- collision

const round = (v) => Math.round(v * 1000) / 1000;

// Gameplay collision data, in the same (glTF) coordinates as the map:
// - heightfield: terrain vertex heights on a regular grid, row by row from
//   z = -size/2, column by column from x = -size/2. Triangles split along the
//   (x0, z1)-(x1, z0) diagonal, exactly like the rendered terrain mesh.
// - boxes: oriented boxes { c: center, h: half extents, yaw } for walls,
//   floors, stairs and cover. Box tops act as floors, so stairs and upper
//   storeys are walkable.
// - circles: [x, z, radius] for tree trunks and big rocks.
function collectCollision(map) {
  map.updateMatrixWorld(true);
  const terrain = map.getObjectByName('Terrain');
  const pos = terrain.geometry.attributes.position;
  const heights = new Array(pos.count);
  for (let i = 0; i < pos.count; i++) heights[i] = round(pos.getY(i));

  const boxes = [];
  const p = new THREE.Vector3(), q = new THREE.Quaternion(), sc = new THREE.Vector3();
  const e = new THREE.Euler();
  map.traverse((o) => {
    if (!o.colliderBoxes) return;
    for (const { matrix, size } of o.colliderBoxes) {
      new THREE.Matrix4().multiplyMatrices(o.matrixWorld, matrix).decompose(p, q, sc);
      e.setFromQuaternion(q, 'YXZ');
      boxes.push({
        c: [round(p.x), round(p.y), round(p.z)],
        h: [round(size[0] * sc.x / 2), round(size[1] * sc.y / 2), round(size[2] * sc.z / 2)],
        yaw: round(e.y),
      });
    }
  });

  const segments = Math.round(Math.sqrt(pos.count)) - 1;
  return {
    size: MAP_SIZE,
    seaLevel: SEA_LEVEL,
    heightfield: { segments, heights },
    boxes,
    circles: circleColliders.map((c) => c.map(round)),
  };
}
