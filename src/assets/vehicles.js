import * as THREE from 'three';
import { bakeAll, bakedMaterial } from './bake.js';

// The drop plane, the parachute and the small loot props. Each is baked to a
// single vertex-colored mesh (the plane keeps its propellers separate so the
// game can spin them).

const deg = THREE.MathUtils.degToRad;

function part(parent, name, geometry, color, x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0) {
  const m = new THREE.Mesh(geometry, new THREE.MeshStandardMaterial({ color }));
  m.name = name;
  m.position.set(x, y, z);
  m.rotation.set(rx, ry, rz);
  parent.add(m);
  return m;
}

// Military transport, ~28 m long, nose toward +Z, wings on top.
export function createAirplane() {
  const plane = new THREE.Group();
  plane.name = 'Airplane';
  const body = 0x6f7a72, dark = 0x3b423d, glass = 0x1d2b33, stripe = 0xc9a43a;

  // Fuselage: lathe profile along the length, rotated onto Z.
  const profile = [
    [0.01, -14], [0.9, -13.5], [1.5, -11], [1.9, -7], [2.0, 0], [2.0, 8], [1.85, 11], [1.4, 13], [0.6, 14.2], [0.01, 14.5],
  ].map(([r, y]) => new THREE.Vector2(r, y));
  const fuselage = new THREE.LatheGeometry(profile, 20);
  fuselage.rotateX(Math.PI / 2);
  part(plane, 'Fuselage', fuselage, body);
  // Tail sweeps up: a wedge above the rear fuselage.
  part(plane, 'TailBoom', new THREE.BoxGeometry(1.6, 1.4, 6), body, 0, 1.1, -11.5, deg(-8));
  part(plane, 'Fin', new THREE.BoxGeometry(0.35, 6, 4), body, 0, 4.2, -12.5, deg(-12));
  part(plane, 'Stabilizer', new THREE.BoxGeometry(12, 0.3, 3), body, 0, 2.2, -13);
  // Cockpit glass and a marking stripe.
  part(plane, 'Windshield', new THREE.BoxGeometry(2.4, 0.7, 1.6), glass, 0, 1.15, 12.2, deg(25));
  for (const s of [-1, 1]) {
    part(plane, 'SideWindow', new THREE.BoxGeometry(0.1, 0.5, 1.2), glass, s * 1.75, 1.1, 11.3);
    for (let i = 0; i < 6; i++) {
      part(plane, 'Porthole', new THREE.CylinderGeometry(0.22, 0.22, 0.1, 10), glass, s * 1.98, 0.4, 6 - i * 2.4, 0, 0, deg(90));
    }
  }
  part(plane, 'Stripe', new THREE.CylinderGeometry(2.02, 2.02, 0.6, 20, 1, true), stripe, 0, 0, 4, deg(90));
  // High wing with four engines.
  part(plane, 'Wing', new THREE.BoxGeometry(34, 0.45, 4.2), body, 0, 1.9, 2);
  part(plane, 'WingRoot', new THREE.BoxGeometry(4, 0.9, 4.2), body, 0, 1.6, 2);
  for (const x of [-11, -5.5, 5.5, 11]) {
    part(plane, 'Nacelle', new THREE.CylinderGeometry(0.75, 0.6, 4.2, 14), dark, x, 1.5, 3.4, deg(90));
    part(plane, 'Spinner', new THREE.ConeGeometry(0.35, 0.8, 12), dark, x, 1.5, 5.9, deg(90));
  }
  // Landing gear pods.
  for (const s of [-1, 1]) part(plane, 'GearPod', new THREE.BoxGeometry(1, 1.2, 5), dark, s * 2.1, -1.2, 1);

  bakeAll(plane, bakedMaterial('AirplanePaint', { roughness: 0.6, metalness: 0.3 }));

  // Propellers: separate nodes so the game can spin them about local Z.
  [-11, -5.5, 5.5, 11].forEach((x, i) => {
    const prop = new THREE.Group();
    prop.name = `Prop${i}`;
    prop.position.set(x, 1.5, 6.1);
    for (let b = 0; b < 4; b++) {
      part(prop, 'Blade', new THREE.BoxGeometry(0.28, 2.1, 0.06), dark, 0, 0, 0, 0, 0, (b * Math.PI) / 2).geometry.translate(0, 1.05, 0);
    }
    bakeAll(prop, bakedMaterial('Propeller', { roughness: 0.5, metalness: 0.4 }));
    plane.add(prop);
  });
  return plane;
}

// Canopy and lines. Origin = the jumper's feet; the harness sits at the
// shoulders (y 1.45), the canopy ~4 m above.
export function createParachute() {
  const chute = new THREE.Group();
  chute.name = 'Parachute';
  const radius = 3.4, gores = 14;
  const canopy = new THREE.SphereGeometry(radius, gores, 5, 0, Math.PI * 2, 0, Math.PI * 0.32).toNonIndexed();
  canopy.scale(1, 0.62, 0.75);
  const pos = canopy.attributes.position;
  const colors = new Float32Array(pos.count * 3);
  const orange = new THREE.Color(0xe8641e), white = new THREE.Color(0xf2efe6);
  const uv = canopy.attributes.uv;
  for (let t = 0; t < pos.count; t += 3) {
    // Color each triangle by the gore (sphere segment) it belongs to; its
    // average U lies strictly inside that segment's U range.
    const u = (uv.getX(t) + uv.getX(t + 1) + uv.getX(t + 2)) / 3;
    const gore = Math.floor(u * gores);
    const c = gore % 2 ? orange : white;
    for (let k = 0; k < 3; k++) colors.set([c.r, c.g, c.b], (t + k) * 3);
  }
  canopy.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  const rimY = 5.4;
  canopy.translate(0, rimY - radius * 0.62 * Math.cos(Math.PI * 0.32), 0);
  const canopyMesh = new THREE.Mesh(canopy, new THREE.MeshStandardMaterial({ vertexColors: true }));
  canopyMesh.name = 'Canopy';
  chute.add(canopyMesh);

  // Lines from the canopy rim to the harness.
  const rimR = radius * Math.sin(Math.PI * 0.32);
  const harness = new THREE.Vector3(0, 1.45, -0.05);
  for (let i = 0; i < 10; i++) {
    const a = (i / 10) * Math.PI * 2;
    const rim = new THREE.Vector3(Math.cos(a) * rimR, rimY, Math.sin(a) * rimR * 0.75);
    const dir = rim.clone().sub(harness);
    const line = new THREE.Mesh(new THREE.CylinderGeometry(0.012, 0.012, dir.length(), 4), new THREE.MeshStandardMaterial({ color: 0x2a2a2a }));
    line.name = 'Line';
    line.position.copy(harness).addScaledVector(dir, 0.5);
    line.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), dir.normalize());
    chute.add(line);
  }
  part(chute, 'Pack', new THREE.BoxGeometry(0.34, 0.4, 0.14), 0x3b423d, 0, 1.25, -0.2);
  bakeAll(chute, bakedMaterial('ParachuteFabric', { roughness: 0.9 }));
  return chute;
}

export function createMedkit() {
  const kit = new THREE.Group();
  kit.name = 'Medkit';
  part(kit, 'Case', new THREE.BoxGeometry(0.36, 0.2, 0.26), 0xeeeeea, 0, 0.1, 0);
  for (const [w, d] of [[0.2, 0.06], [0.06, 0.2]]) {
    part(kit, 'Cross', new THREE.BoxGeometry(w, 0.01, d), 0xd2231e, 0, 0.205, 0);
    part(kit, 'CrossSide', new THREE.BoxGeometry(w * 0.7, d * 0.7 * 2.2, 0.01), 0xd2231e, 0, 0.1, 0.131);
  }
  part(kit, 'Handle', new THREE.TorusGeometry(0.06, 0.012, 6, 12, Math.PI), 0x333333, 0, 0.2, 0);
  bakeAll(kit, bakedMaterial('Medkit', { roughness: 0.6 }));
  kit.userData = { type: 'medkit', heal: 75 };
  return kit;
}

export function createAmmoBox() {
  const box = new THREE.Group();
  box.name = 'AmmoBox';
  part(box, 'Box', new THREE.BoxGeometry(0.32, 0.17, 0.18), 0x4d5a37, 0, 0.085, 0);
  part(box, 'Lid', new THREE.BoxGeometry(0.33, 0.03, 0.19), 0x3d4a2a, 0, 0.18, 0);
  for (let i = 0; i < 5; i++) {
    part(box, 'Round', new THREE.CylinderGeometry(0.012, 0.012, 0.07, 6), 0xb08d3c, -0.1 + i * 0.05, 0.23, 0);
  }
  part(box, 'Stencil', new THREE.BoxGeometry(0.14, 0.05, 0.005), 0xd8d2b0, 0, 0.09, 0.091);
  bakeAll(box, bakedMaterial('AmmoBox', { roughness: 0.7 }));
  box.userData = { type: 'ammo' };
  return box;
}
