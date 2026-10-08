import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { Sculpt, ellipsoid, roundBox, sphere, taper } from './sdf.js';
import { meshField } from './mesher.js';
import { createHumanAnimations } from './animations.js';

// A realistic soldier: one continuous, smoothly skinned body sculpted from
// anatomical volumes, a separately sculpted head with facial features, and
// rigid gear. Same joint names as the old rig (Hips, Spine, Chest, Neck,
// Head, Left/RightShoulder, Arm, ForeArm, Hand, UpLeg, Leg, Foot, ToeBase),
// 1.80 m tall, feet at y = 0, facing +Z. Guns attach to "RightHandSocket".

const deg = THREE.MathUtils.degToRad;

// camo: base, then three blotch colors layered on top.
export const OUTFITS = {
  default: {
    shirt: 0x5b6440, pants: 0x4a5236, vest: 0x2f3427, skin: 0xb98563, hair: 0x1f1813, cap: 0x3a4030,
    camo: [0x6d7549, 0x3f4d2a, 0x5b4831, 0x1e1f19],
  },
  desert: {
    shirt: 0xb8a47c, pants: 0x9a8762, vest: 0x6a5c40, skin: 0xc99474, hair: 0x2a1d14, cap: 0x8c7a57,
    camo: [0xc4b088, 0xa08a5e, 0x7d6545, 0xd9cba6],
  },
  urban: {
    shirt: 0x6a6d72, pants: 0x45484d, vest: 0x24272b, skin: 0x8a5a3c, hair: 0x111111, cap: 0x2b2e33,
    camo: [0x7a7d82, 0x55585d, 0x2e3135, 0xa7aaae],
  },
  red: {
    shirt: 0x7c2f2a, pants: 0x3b3431, vest: 0x2b2b2b, skin: 0xe0b49c, hair: 0x5e4128, cap: 0x2b2b2b,
    camo: null,
  },
  navy: {
    shirt: 0x34507a, pants: 0x2b3340, vest: 0x1d2633, skin: 0x6e4632, hair: 0x0d0d0d, cap: 0x1d2633,
    camo: [0x3c5476, 0x2a3b55, 0x1c2638, 0x5a7194],
  },
};

// ------------------------------------------------------------------ skeleton

// [name, parent, local position, rest rotation (deg, XYZ)]
function boneTable() {
  const t = [
    ['Hips', null, [0, 0.98, 0]],
    ['Spine', 'Hips', [0, 0.08, -0.01]],
    ['Chest', 'Spine', [0, 0.18, 0]],
    ['Neck', 'Chest', [0, 0.23, -0.02]],
    ['Head', 'Neck', [0, 0.11, 0.015]],
  ];
  for (const s of [1, -1]) {
    const side = s > 0 ? 'Left' : 'Right';
    t.push(
      [`${side}Shoulder`, 'Chest', [0.03 * s, 0.19, 0]],
      [`${side}Arm`, `${side}Shoulder`, [0.155 * s, 0, -0.015], [0, 0, 8 * s]],
      [`${side}ForeArm`, `${side}Arm`, [0, -0.285, 0], [-10, 0, 0]],
      [`${side}Hand`, `${side}ForeArm`, [0, -0.255, 0]],
      [`${side}UpLeg`, 'Hips', [0.092 * s, -0.06, 0]],
      [`${side}Leg`, `${side}UpLeg`, [0, -0.43, 0]],
      [`${side}Foot`, `${side}Leg`, [0, -0.41, -0.01]],
      [`${side}ToeBase`, `${side}Foot`, [0, -0.05, 0.13]],
    );
  }
  return t;
}

function buildSkeleton() {
  const bones = {};
  const list = [];
  for (const [name, parent, pos, rot = [0, 0, 0]] of boneTable()) {
    const b = new THREE.Bone();
    b.name = name;
    b.position.set(...pos);
    b.rotation.set(deg(rot[0]), deg(rot[1]), deg(rot[2]));
    if (parent) bones[parent].add(b);
    bones[name] = b;
    list.push(b);
  }
  bones.Hips.updateMatrixWorld(true);
  const J = {};
  for (const [name, b] of Object.entries(bones)) {
    const p = new THREE.Vector3().setFromMatrixPosition(b.matrixWorld);
    J[name] = [p.x, p.y, p.z];
  }
  return { bones, list, J };
}

// Each bone's influence segment: from its joint to its child's joint (or a
// short stub for end bones).
function boneSegments(bones, J) {
  const seg = {};
  const childOf = {
    Hips: 'Spine', Spine: 'Chest', Chest: 'Neck', Neck: 'Head',
    LeftShoulder: 'LeftArm', LeftArm: 'LeftForeArm', LeftForeArm: 'LeftHand',
    LeftUpLeg: 'LeftLeg', LeftLeg: 'LeftFoot', LeftFoot: 'LeftToeBase',
    RightShoulder: 'RightArm', RightArm: 'RightForeArm', RightForeArm: 'RightHand',
    RightUpLeg: 'RightLeg', RightLeg: 'RightFoot', RightFoot: 'RightToeBase',
  };
  for (const name of Object.keys(bones)) {
    const a = J[name];
    let b;
    if (childOf[name]) b = J[childOf[name]];
    else if (name === 'Head') b = [a[0], a[1] + 0.2, a[2]];
    else if (name.endsWith('Hand')) {
      const f = J[name.replace('Hand', 'ForeArm')];
      const d = [a[0] - f[0], a[1] - f[1], a[2] - f[2]];
      const l = Math.hypot(...d);
      b = [a[0] + (d[0] / l) * 0.17, a[1] + (d[1] / l) * 0.17, a[2] + (d[2] / l) * 0.17];
    } else b = [a[0], a[1] - 0.02, a[2] + 0.08]; // toe stub
    seg[name] = [a, b];
  }
  return seg;
}

const neighbors = {
  Hips: ['Spine', 'LeftUpLeg', 'RightUpLeg'],
  Spine: ['Hips', 'Chest'],
  Chest: ['Spine', 'Neck', 'LeftShoulder', 'RightShoulder'],
  Neck: ['Chest', 'Head'],
  Head: ['Neck'],
};
for (const side of ['Left', 'Right']) {
  Object.assign(neighbors, {
    [`${side}Shoulder`]: ['Chest', `${side}Arm`],
    [`${side}Arm`]: [`${side}Shoulder`, `${side}ForeArm`, 'Chest'],
    [`${side}ForeArm`]: [`${side}Arm`, `${side}Hand`],
    [`${side}Hand`]: [`${side}ForeArm`],
    [`${side}UpLeg`]: ['Hips', `${side}Leg`],
    [`${side}Leg`]: [`${side}UpLeg`, `${side}Foot`],
    [`${side}Foot`]: [`${side}Leg`, `${side}ToeBase`],
    [`${side}ToeBase`]: [`${side}Foot`],
  });
}

function segDistance(p, [a, b]) {
  const ab = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
  const ap = [p[0] - a[0], p[1] - a[1], p[2] - a[2]];
  const l2 = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2];
  const t = Math.max(0, Math.min(1, (ap[0] * ab[0] + ap[1] * ab[1] + ap[2] * ab[2]) / l2));
  return Math.hypot(ap[0] - ab[0] * t, ap[1] - ab[1] * t, ap[2] - ab[2] * t);
}

// Smooth weights: the owning bone and its neighbours, by inverse distance to
// each bone's segment, top 4 kept.
function skinWeightsFor(p, bone, seg, index) {
  const cands = [bone, ...(neighbors[bone] ?? [])];
  const w = cands.map((b) => {
    const d = segDistance(p, seg[b]);
    return [b, 1 / Math.pow(d * d + 1e-5, 2) * (b === bone ? 1.6 : 1)];
  });
  w.sort((a, b) => b[1] - a[1]);
  const top = w.slice(0, 4);
  const sum = top.reduce((s, x) => s + x[1], 0);
  const idx = [0, 0, 0, 0], wt = [0, 0, 0, 0];
  top.forEach(([b, v], i) => {
    idx[i] = index[b];
    wt[i] = v / sum;
  });
  return [idx, wt];
}

// ------------------------------------------------------------------ helpers

const add3 = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const lerp3 = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
const smooth = (a, b, x) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

function hash3(x, y, z) {
  const s = Math.sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453;
  return s - Math.floor(s);
}

// Cheap smooth 3D value noise in [0, 1].
function noise3(x, y, z) {
  const xi = Math.floor(x), yi = Math.floor(y), zi = Math.floor(z);
  const xf = x - xi, yf = y - yi, zf = z - zi;
  const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf), w = zf * zf * (3 - 2 * zf);
  let r = 0;
  for (let c = 0; c < 8; c++) {
    const dx = c & 1, dy = (c >> 1) & 1, dz = (c >> 2) & 1;
    r += hash3(xi + dx, yi + dy, zi + dz) * (dx ? u : 1 - u) * (dy ? v : 1 - v) * (dz ? w : 1 - w);
  }
  return r;
}

const color = (hex) => new THREE.Color(hex);

// Woodland-style camouflage: soft-edged blotches from layered noise.
function camo(p, outfit, fallback) {
  const pal = outfit.camo;
  if (!pal) return color(fallback);
  const f = 6.5;
  const n1 = noise3(p[0] * f, p[1] * f * 0.8, p[2] * f);
  const n2 = noise3(p[0] * f + 31.7, p[1] * f * 0.8 + 5.1, p[2] * f + 17.3);
  const n3 = noise3(p[0] * f * 1.9 + 7.7, p[1] * f * 1.6, p[2] * f * 1.9 + 3.3);
  const c = color(pal[0]);
  c.lerp(color(pal[1]), smooth(0.49, 0.57, n1));
  c.lerp(color(pal[2]), smooth(0.57, 0.65, n2));
  c.lerp(color(pal[3]), smooth(0.68, 0.75, n3));
  return c;
}

// ------------------------------------------------------------------ body

function sculptBody(J) {
  const S = new Sculpt();
  const L = (mat, bone) => ({ mat, bone });

  // Pelvis, belly, ribcage, chest and back.
  S.add(ellipsoid([0, 0.955, -0.005], [0.158, 0.105, 0.105]), L('torso', 'Hips'), 0.03);
  for (const s of [1, -1]) S.add(ellipsoid([s * 0.068, 0.9, -0.06], [0.085, 0.095, 0.072]), L('torso', 'Hips'), 0.04);
  S.add(ellipsoid([0, 1.04, 0.01], [0.138, 0.09, 0.094]), L('torso', 'Spine'), 0.04);
  S.add(ellipsoid([0, 1.13, 0.008], [0.135, 0.11, 0.09]), L('torso', 'Spine'), 0.04);
  S.add(ellipsoid([0, 1.27, -0.01], [0.152, 0.165, 0.1]), L('torso', 'Chest'), 0.05);
  S.add(ellipsoid([0, 1.38, -0.045], [0.128, 0.08, 0.068]), L('torso', 'Chest'), 0.04);
  for (const s of [1, -1]) {
    const side = s > 0 ? 'Left' : 'Right';
    S.add(ellipsoid([s * 0.068, 1.3, 0.052], [0.08, 0.058, 0.045]), L('torso', 'Chest'), 0.03);
    S.add(ellipsoid([s * 0.108, 1.25, -0.03], [0.058, 0.12, 0.066]), L('torso', 'Chest'), 0.04);
    S.add(taper([0, 1.49, -0.03], [s * 0.16, 1.445, -0.02], 0.056, 0.042), L('torso', 'Chest'), 0.045);

    // Shoulder and arm.
    const arm = J[`${side}Arm`], elbow = J[`${side}ForeArm`], wrist = J[`${side}Hand`];
    S.add(ellipsoid(add3(arm, [s * 0.012, -0.005, 0]), [0.054, 0.062, 0.058]), L('shirt', `${side}Arm`), 0.035);
    S.add(taper(arm, elbow, 0.046, 0.037), L('shirt', `${side}Arm`), 0.02);
    S.add(ellipsoid(add3(lerp3(arm, elbow, 0.48), [0, 0, 0.014]), [0.034, 0.072, 0.033]), L('shirt', `${side}Arm`), 0.025);
    S.add(ellipsoid(add3(lerp3(arm, elbow, 0.4), [0, 0, -0.016]), [0.034, 0.085, 0.034]), L('shirt', `${side}Arm`), 0.025);
    // Forearm: rolled sleeve cuff, then bare skin.
    const fore = { mat: 'forearm', bone: `${side}ForeArm`, elbow, wrist };
    S.add(taper(lerp3(elbow, wrist, 0.03), lerp3(elbow, wrist, 0.15), 0.045, 0.043), fore, 0.01);
    S.add(taper(elbow, wrist, 0.04, 0.026), fore, 0.02);
    S.add(ellipsoid(add3(lerp3(elbow, wrist, 0.27), [s * 0.004, 0, 0.004]), [0.037, 0.065, 0.033]), fore, 0.03);
    // (Hands are sculpted separately at finer resolution: see sculptHand.)

    // Leg.
    const hip = J[`${side}UpLeg`], knee = J[`${side}Leg`], ankle = J[`${side}Foot`], toe = J[`${side}ToeBase`];
    S.add(taper(add3(hip, [0, 0.02, 0]), knee, 0.084, 0.052), L('pants', `${side}UpLeg`), 0.04);
    S.add(ellipsoid(add3(lerp3(hip, knee, 0.42), [s * 0.008, 0, 0.022]), [0.06, 0.14, 0.055]), L('pants', `${side}UpLeg`), 0.03);
    S.add(ellipsoid(add3(lerp3(hip, knee, 0.45), [0, 0, -0.026]), [0.055, 0.13, 0.05]), L('pants', `${side}UpLeg`), 0.03);
    S.add(sphere(add3(knee, [0, 0, 0.008]), 0.05), L('pants', `${side}Leg`), 0.025);
    S.add(taper(knee, add3(ankle, [0, 0.05, 0]), 0.05, 0.036), L('pants', `${side}Leg`), 0.025);
    S.add(ellipsoid(add3(lerp3(knee, ankle, 0.3), [0, 0, -0.026]), [0.048, 0.095, 0.045]), L('pants', `${side}Leg`), 0.03);
    // Cargo pocket on the outer thigh, and trousers bloused over the boots.
    const pocketAt = add3(lerp3(hip, knee, 0.52), [s * 0.066, 0, 0.012]);
    S.add(roundBox(pocketAt, [0.012, 0.058, 0.046], 0.008), { mat: 'pocket', bone: `${side}UpLeg`, top: pocketAt[1] + 0.066 }, 0.01);
    S.add(ellipsoid(add3(ankle, [0, 0.185, 0.0]), [0.058, 0.032, 0.062]), L('pants', `${side}Leg`), 0.02);
    // Combat boot: shaft, foot and toe box, then a sole.
    const bootL = { mat: 'boot', bone: `${side}Foot`, ankleX: ankle[0], ankleZ: ankle[2] };
    S.add(taper(add3(ankle, [0, 0.17, -0.005]), add3(ankle, [0, 0.0, -0.005]), 0.052, 0.05), bootL, 0.015);
    S.add(roundBox(add3(ankle, [0, -0.04, 0.035]), [0.036, 0.03, 0.09], 0.016), L('boot', `${side}Foot`), 0.03);
    S.add(roundBox(add3(toe, [0, -0.012, 0.028]), [0.038, 0.026, 0.045], 0.018), L('boot', `${side}ToeBase`), 0.03);
    S.add(roundBox([ankle[0], 0.011, ankle[2] + 0.06], [0.046, 0.011, 0.14], 0.006), L('sole', `${side}Foot`), 0.005);
  }
  return S;
}

function bodyColor(label, p, outfit) {
  const n = noise3(p[0] * 60, p[1] * 60, p[2] * 60);
  let c;
  switch (label.mat) {
    case 'torso': c = p[1] > 1.0 ? camo(p, outfit, outfit.shirt) : camo(p, outfit, outfit.pants).multiplyScalar(0.92); break;
    case 'shirt': c = camo(p, outfit, outfit.shirt); break;
    case 'pocket': c = camo(p, outfit, outfit.pants).multiplyScalar(p[1] > label.top - 0.022 ? 0.75 : 0.95); break;
    case 'forearm': {
      // Sleeve rolled up just below the elbow: a clean, straight edge.
      const e = label.elbow, w = label.wrist;
      const ew = [w[0] - e[0], w[1] - e[1], w[2] - e[2]];
      const t = ((p[0] - e[0]) * ew[0] + (p[1] - e[1]) * ew[1] + (p[2] - e[2]) * ew[2]) / (ew[0] ** 2 + ew[1] ** 2 + ew[2] ** 2);
      c = t < 0.15 ? camo(p, outfit, outfit.shirt) : color(outfit.skin);
      break;
    }
    case 'pants': c = camo(p, outfit, outfit.pants).multiplyScalar(0.92); break;
    case 'boot': {
      c = color(p[1] < 0.03 ? 0x151311 : 0x2e241b);
      // Laces criss-crossing up the front of the boot.
      const front = p[2] - label.ankleZ;
      if (front > 0.03 && p[1] > 0.05 && p[1] < 0.2 && Math.abs(p[0] - label.ankleX) < 0.022) {
        if ((p[1] * 80) % 1 < 0.4) c = color(0x6b5a44);
      }
      break;
    }
    case 'sole': c = color(0x141312); break;
    case 'glove': c = color(0x1b1b1b); break;
    default: c = color(outfit.skin);
  }
  if (label.mat === 'skin' || label.mat === 'forearm') {
    // Slightly redder skin over the knuckles and elbows.
    c.lerp(color(0xb5644e), 0.12 * n);
  }
  return c.multiplyScalar(0.95 + 0.07 * n);
}

// Fabric folds: soft wrinkles on clothes only.
function clothDetail(label, p) {
  if (!['torso', 'shirt', 'pants', 'pocket'].includes(label.mat)) return 0;
  return (noise3(p[0] * 22, p[1] * 9, p[2] * 22) - 0.5) * 0.0016;
}

// ------------------------------------------------------------------ hands

const norm3 = (a) => {
  const l = Math.hypot(a[0], a[1], a[2]);
  return [a[0] / l, a[1] / l, a[2] / l];
};
const scale3 = (a, k) => [a[0] * k, a[1] * k, a[2] * k];
const cross3 = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];

// Rotate v toward axis `to` (both unit, roughly orthogonal) by angle a.
const bend = (v, to, a) => norm3(add3(scale3(v, Math.cos(a)), scale3(to, Math.sin(a))));

/**
 * One relaxed hand in fingerless tactical gloves: palm, four fingers with
 * three segments each curling slightly toward the palm, and a thumb.
 */
function sculptHand(J, side) {
  const s = side === 'Left' ? 1 : -1;
  const bone = `${side}Hand`;
  const S = new Sculpt();
  const glove = { mat: 'glove', bone };
  const tip = { mat: 'skin', bone };
  const wrist = J[bone], elbow = J[`${side}ForeArm`];
  const d = norm3([wrist[0] - elbow[0], wrist[1] - elbow[1], wrist[2] - elbow[2]]);
  // Palm faces the thigh (inward, -s on X); forward is +Z.
  const palm = norm3(cross3(d, [0, 0, s]));
  const fwd = norm3(cross3(palm, d));
  const at = (t, z = 0, n = 0) => add3(add3(add3(wrist, scale3(d, t)), scale3(fwd, z)), scale3(palm, n));

  // Glove cuff over the wrist, then the palm.
  S.add(taper(at(-0.03), at(0.015), 0.03, 0.03), glove, 0.01);
  // Palm: two overlapping flattened volumes along the hand.
  S.add(taper(at(0.02, 0.012, -0.002), at(0.085, 0.014, 0.0), 0.017, 0.015), glove, 0.02);
  S.add(taper(at(0.02, -0.014, -0.002), at(0.085, -0.016, 0.0), 0.016, 0.014), glove, 0.02);

  // Fingers, index (front) to pinky (back).
  const fingers = [
    [0.026, 0.078, 0.0095],
    [0.0085, 0.086, 0.0098],
    [-0.0085, 0.081, 0.0094],
    [-0.025, 0.065, 0.0085],
  ];
  for (const [z, length, r] of fingers) {
    let p = at(0.093, z, 0.002);
    let dir = d;
    const segs = [0.45, 0.31, 0.24];
    const curl = [0.22, 0.32, 0.26];
    segs.forEach((frac, i) => {
      dir = bend(dir, palm, curl[i]);
      const q = add3(p, scale3(dir, length * frac));
      const rr = r * (1 - 0.1 * i);
      S.add(taper(p, q, rr, rr * 0.92), i < 2 ? glove : tip, 0.005);
      p = q;
    });
  }
  // Thumb: from the base of the palm, forward and down along the index.
  let tp = at(0.03, 0.022, 0.006);
  let tdir = norm3(add3(add3(scale3(d, 0.8), scale3(fwd, 0.45)), scale3(palm, 0.35)));
  for (const [len, r, mat] of [[0.035, 0.012, glove], [0.03, 0.0105, glove], [0.026, 0.0095, tip]]) {
    const q = add3(tp, scale3(tdir, len));
    S.add(taper(tp, q, r, r * 0.92), mat, 0.006);
    tp = q;
    tdir = bend(tdir, palm, 0.25);
  }
  const center = at(0.08);
  return { S, min: add3(center, [-0.12, -0.12, -0.12]), max: add3(center, [0.12, 0.12, 0.12]) };
}

// ------------------------------------------------------------------ head

function sculptHead(c, withCap) {
  const S = new Sculpt();
  const at = (x, y, z) => [c[0] + x, c[1] + y, c[2] + z];
  const L = (mat, bone = 'Head') => ({ mat, bone });
  S.add(ellipsoid(at(0, 0.025, -0.012), [0.07, 0.088, 0.097]), L('skin'), 0.02);
  S.add(ellipsoid(at(0, 0.0, -0.04), [0.066, 0.075, 0.074]), L('skin'), 0.03);
  S.add(ellipsoid(at(0, 0.04, 0.045), [0.066, 0.05, 0.048]), L('skin'), 0.03);
  S.add(ellipsoid(at(0, -0.035, 0.038), [0.051, 0.06, 0.055]), L('skin'), 0.03);
  S.add(ellipsoid(at(0, -0.1, 0.064), [0.019, 0.016, 0.017]), L('skin'), 0.022);
  for (const s of [1, -1]) {
    S.add(taper(at(s * 0.053, -0.028, -0.014), at(s * 0.018, -0.097, 0.058), 0.017, 0.015), L('skin'), 0.025);
    S.add(ellipsoid(at(s * 0.046, -0.003, 0.058), [0.022, 0.014, 0.02]), L('skin'), 0.02);
    S.add(ellipsoid(at(s * 0.036, -0.042, 0.055), [0.019, 0.024, 0.02]), L('skin'), 0.025);
    // Ears.
    S.add(ellipsoid(at(s * 0.076, -0.002, -0.012), [0.011, 0.031, 0.021]), L('ear'), 0.008);
  }
  S.add(ellipsoid(at(0, 0.031, 0.083), [0.058, 0.013, 0.018]), L('skin'), 0.02);
  for (const s of [1, -1]) {
    S.cut(sphere(at(s * 0.031, 0.012, 0.094), 0.0185), 0.012);
    S.cut(sphere(at(s * 0.086, -0.004, -0.008), 0.0085), 0.004);
    // Upper and lower eyelids frame the eye.
    S.add(ellipsoid(at(s * 0.031, 0.0228, 0.083), [0.0185, 0.0072, 0.0112]), L('skin'), 0.005);
    S.add(ellipsoid(at(s * 0.031, 0.0, 0.081), [0.016, 0.0042, 0.0095]), L('skin'), 0.004);
  }
  // Nose: bridge, tip, wings.
  S.add(taper(at(0, 0.02, 0.092), at(0, -0.021, 0.112), 0.0075, 0.0105), L('skin'), 0.012);
  S.add(sphere(at(0, -0.025, 0.109), 0.0098), L('nose'), 0.01);
  for (const s of [1, -1]) S.add(sphere(at(s * 0.0115, -0.03, 0.102), 0.0075), L('nose'), 0.006);
  // Lips and mouth line.
  S.add(ellipsoid(at(0, -0.053, 0.083), [0.02, 0.0055, 0.0075]), L('lip'), 0.006);
  S.add(ellipsoid(at(0, -0.064, 0.081), [0.018, 0.006, 0.0075]), L('lip'), 0.006);
  // Tactical cap: crown just over the skull, cut off along a tilted band
  // (lower at the back), plus a curved brim.
  if (withCap) {
    const crown = ellipsoid(at(0, 0.043, -0.01), [0.078, 0.077, 0.104]);
    S.add({
      bounds: crown.bounds,
      f: (p) => {
        const y = p[1] - c[1], z = p[2] - c[2];
        const bottom = 0.046 + 0.28 * z;
        return Math.max(crown.f(p), bottom - y);
      },
    }, L('cap'), 0.004);
    // Brim: a thin, gently curved shell attached at the crown's front edge.
    const brim = ellipsoid(at(0, 0.064, 0.098), [0.072, 0.012, 0.062]);
    S.add({
      bounds: brim.bounds,
      f: (p) => {
        const y = p[1] - c[1], z = p[2] - c[2];
        // Keep a 4 mm sheet that dips toward the front, only ahead of the forehead.
        const sheet = Math.abs(y - (0.066 - 0.12 * Math.max(0, z - 0.08))) - 0.002;
        return Math.max(brim.f(p), sheet, 0.075 - z);
      },
    }, L('cap'), 0.004);
  }
  // Neck with the two neck muscles.
  S.add(taper(at(0, -0.06, -0.022), [0, 1.42, -0.02], 0.061, 0.066), L('skin', 'Neck'), 0.035);
  return S;
}

function headColor(label, p, c, outfit) {
  const x = p[0] - c[0], y = p[1] - c[1], z = p[2] - c[2];
  const skin = color(outfit.skin);
  const hair = color(outfit.hair);
  const n = noise3(p[0] * 300, p[1] * 300, p[2] * 300);
  let out = skin.clone();
  if (label.mat === 'cap') return color(outfit.cap).multiplyScalar(0.93 + 0.1 * noise3(p[0] * 120, p[1] * 120, p[2] * 120));
  if (label.mat === 'lip') out.lerp(color(0x9a4f45), 0.5);
  if (label.mat === 'nose') out.lerp(color(0xc0705c), 0.12);
  if (label.mat === 'ear') out.lerp(color(0xc0705c), 0.18);
  // Rosy cheeks.
  for (const s of [1, -1]) {
    const d = Math.hypot(x - s * 0.042, y + 0.03, z - 0.06);
    out.lerp(color(0xc0705c), 0.12 * (1 - smooth(0.0, 0.03, d)));
  }
  // Short military haircut: hairline high at the front, low at the back.
  const front = 0.067, side = 0.028, back = -0.05;
  const line = z > 0.02 ? side + (front - side) * smooth(0.02, 0.06, z) : back + (side - back) * smooth(-0.06, 0.02, z);
  const aboveEar = Math.abs(x) > 0.062 && y < 0.035 && y > -0.035 && z > -0.035 && z < 0.025;
  const hairAmount = aboveEar ? 0 : smooth(line - 0.004, line + 0.006, y) * (0.82 + 0.18 * n);
  out.lerp(hair, hairAmount * 0.9);
  // Eyebrows: a soft arch over each eye, a little thicker toward the nose.
  const bx = Math.abs(x) - 0.031;
  if (z > 0.07 && Math.abs(bx) < 0.021) {
    const browY = 0.031 + 0.0025 * (1 - (bx / 0.021) ** 2);
    const half = bx < 0 ? 0.0052 : 0.0038;
    const amount = 1 - smooth(half * 0.6, half, Math.abs(y - browY));
    out.lerp(hair, 0.8 * amount * (0.7 + 0.3 * n));
  }
  // Stubble on jaw, chin and upper lip.
  if (label.mat !== 'lip' && y < -0.035 && z > -0.03) {
    const amt = smooth(-0.035, -0.06, y) * smooth(-0.03, 0.02, z) * 0.28;
    out.lerp(color(0x2e2a28), amt * (0.6 + 0.4 * n));
  }
  return out.multiplyScalar(0.95 + 0.08 * noise3(p[0] * 80, p[1] * 80, p[2] * 80));
}

function eyeballs(c) {
  const parts = [];
  for (const s of [1, -1]) {
    // Pole facing forward so the iris and pupil follow the sphere's rings.
    const g = new THREE.SphereGeometry(0.0122, 32, 24);
    g.rotateX(Math.PI / 2);
    const pos = g.attributes.position;
    const colors = new Float32Array(pos.count * 3);
    for (let i = 0; i < pos.count; i++) {
      const cz = pos.getZ(i) / 0.0122;
      const col = cz > 0.96 ? color(0x0b0807) : cz > 0.84 ? color(0x4a3524).lerp(color(0x6b5038), (cz - 0.84) / 0.12) : color(0xd8d1c6);
      colors.set([col.r, col.g, col.b], i * 3);
    }
    g.setAttribute('color', new THREE.BufferAttribute(colors, 3));
    g.translate(c[0] + s * 0.031, c[1] + 0.0115, c[2] + 0.0785);
    parts.push(g);
  }
  return parts;
}

// ------------------------------------------------------------------ gear

function gear(J, outfit, low) {
  const seg = low ? 1 : 3;
  const parts = [];
  const put = (geo, hex, bone, x, y, z, rx = 0, ry = 0, rz = 0) => {
    const g = geo;
    g.deleteAttribute('uv');
    g.applyMatrix4(new THREE.Matrix4().compose(
      new THREE.Vector3(x, y, z),
      new THREE.Quaternion().setFromEuler(new THREE.Euler(rx, ry, rz)),
      new THREE.Vector3(1, 1, 1),
    ));
    const c = color(hex);
    const colors = new Float32Array(g.attributes.position.count * 3);
    for (let i = 0; i < colors.length; i += 3) colors.set([c.r, c.g, c.b], i);
    g.setAttribute('color', new THREE.BufferAttribute(colors, 3));
    parts.push({ geo: g, bone });
  };
  const box = (w, h, d, r) => new RoundedBoxGeometry(w, h, d, seg, r);
  const vest = outfit.vest, pouch = new THREE.Color(outfit.vest).offsetHSL(0, 0, 0.04).getHex(), strap = 0x1c1d19;

  // Plate carrier.
  put(box(0.29, 0.29, 0.05, 0.016), vest, 'Chest', 0, 1.29, 0.118, deg(-4));
  put(box(0.29, 0.31, 0.045, 0.016), vest, 'Chest', 0, 1.29, -0.128, deg(3));
  for (const s of [1, -1]) {
    put(box(0.055, 0.022, 0.25, 0.008), vest, 'Chest', s * 0.095, 1.452, -0.005);
    put(box(0.03, 0.15, 0.2, 0.01), vest, 'Chest', s * 0.152, 1.23, -0.005);
  }
  for (let i = 0; i < 3; i++) {
    put(box(0.074, 0.1, 0.04, 0.01), pouch, 'Chest', (i - 1) * 0.084, 1.22, 0.158);
    put(box(0.077, 0.028, 0.045, 0.008), strap, 'Chest', (i - 1) * 0.084, 1.27, 0.16);
  }
  put(box(0.06, 0.08, 0.04, 0.01), pouch, 'Chest', 0.09, 1.35, 0.155);
  put(new THREE.CylinderGeometry(0.003, 0.004, 0.14, low ? 4 : 6), strap, 'Chest', 0.108, 1.42, 0.155);
  // Headset: ear cups on the cap band, joined over the top.
  if (J.headCenter) {
    const c = J.headCenter;
    for (const s of [1, -1]) {
      const cup = new THREE.CylinderGeometry(0.031, 0.033, 0.026, low ? 8 : 20);
      cup.rotateZ(Math.PI / 2);
      put(cup, 0x26282a, 'Head', c[0] + s * 0.086, c[1] - 0.004, c[2] - 0.012);
      put(new THREE.CylinderGeometry(0.022, 0.022, 0.006, low ? 8 : 16), 0x3a3d40, 'Head', c[0] + s * 0.1, c[1] - 0.004, c[2] - 0.012, 0, 0, Math.PI / 2);
    }
    const band = new THREE.TorusGeometry(0.093, 0.006, low ? 4 : 6, low ? 12 : 24, Math.PI);
    put(band, 0x1d1f21, 'Head', c[0], c[1] - 0.004, c[2] - 0.012);
    // Boom mic toward the mouth.
    const boom = new THREE.CylinderGeometry(0.0025, 0.0025, 0.075, 6);
    put(boom, 0x1d1f21, 'Head', c[0] - 0.074, c[1] - 0.04, c[2] + 0.04, deg(55), 0, deg(15));
  }
  // Belt, buckle, holster.
  const belt = new THREE.TorusGeometry(0.15, 0.019, low ? 4 : 8, low ? 16 : 40);
  belt.scale(1, 0.74, 1);
  put(belt, strap, 'Hips', 0, 1.0, 0.0, Math.PI / 2);
  put(box(0.05, 0.034, 0.012, 0.004), 0x77756e, 'Hips', 0, 1.0, 0.112);
  put(box(0.045, 0.16, 0.08, 0.012), strap, 'RightUpLeg', -0.17, 0.85, 0.01);
  // Knee pads.
  for (const s of [1, -1]) {
    const side = s > 0 ? 'Left' : 'Right';
    const k = J[`${side}Leg`];
    put(box(0.085, 0.1, 0.035, 0.014), strap, `${side}Leg`, k[0], k[1] - 0.01, k[2] + 0.055);
  }
  return parts;
}

// ------------------------------------------------------------------ assembly

export function createHuman({ outfit = OUTFITS.default, lowDetail = false, cap = true } = {}) {
  const { bones, list, J } = buildSkeleton();
  const seg = boneSegments(bones, J);
  const index = Object.fromEntries(list.map((b, i) => [b.name, i]));

  const meshes = [];
  const addSculpt = (S, min, max, step, colorFn, detail) => {
    const field = (p) => {
      const r = S.evaluate(p);
      return detail ? r.d + detail(r.label ?? { mat: 'skin' }, p) : r.d;
    };
    const m = meshField(field, min, max, step);
    const count = m.positions.length / 3;
    const colors = new Float32Array(count * 3);
    const skinIndex = new Uint16Array(count * 4);
    const skinWeight = new Float32Array(count * 4);
    const skinFlag = new Float32Array(count);
    for (let v = 0; v < count; v++) {
      const p = [m.positions[v * 3], m.positions[v * 3 + 1], m.positions[v * 3 + 2]];
      const label = S.evaluate(p).label ?? { mat: 'skin', bone: 'Chest' };
      const c = colorFn(label, p);
      colors.set([c.r, c.g, c.b], v * 3);
      skinFlag[v] = ['skin', 'forearm', 'lip', 'nose', 'ear'].includes(label.mat) && !(label.mat === 'forearm' && c.equals(camo(p, outfit, outfit.shirt))) ? 1 : 0;
      const [idx, wt] = skinWeightsFor(p, label.bone, seg, index);
      skinIndex.set(idx, v * 4);
      skinWeight.set(wt, v * 4);
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(m.positions, 3));
    g.setAttribute('normal', new THREE.BufferAttribute(m.normals, 3));
    g.setAttribute('color', new THREE.BufferAttribute(colors, 3));
    g.setAttribute('skinIndex', new THREE.BufferAttribute(skinIndex, 4));
    g.setAttribute('skinWeight', new THREE.BufferAttribute(skinWeight, 4));
    g.setAttribute('_skin', new THREE.BufferAttribute(skinFlag, 1));
    g.setIndex(new THREE.BufferAttribute(m.indices, 1));
    meshes.push(g);
  };

  for (const side of ['Left', 'Right']) {
    const hand = sculptHand(J, side);
    addSculpt(hand.S, hand.min, hand.max, lowDetail ? 0.009 : 0.0032, (label, p) => bodyColor(label, p, outfit));
  }

  const body = sculptBody(J);
  addSculpt(body, [-0.36, -0.005, -0.2], [0.36, 1.6, 0.24], lowDetail ? 0.024 : 0.0105,
    (label, p) => bodyColor(label, p, outfit), lowDetail ? null : clothDetail);

  const headCenter = [J.Head[0], J.Head[1] + 0.095, J.Head[2] - 0.012];
  J.headCenter = headCenter;
  const head = sculptHead(headCenter, cap);
  addSculpt(head, [-0.105, 1.38, -0.175], [0.105, 1.84, 0.14], lowDetail ? 0.009 : 0.0034,
    (label, p) => headColor(label, p, headCenter, outfit));

  // Rigid parts: eyes and gear, each fully weighted to one bone.
  const rigid = [...eyeballs(headCenter).map((geo) => ({ geo, bone: 'Head' })), ...gear(J, outfit, lowDetail)];
  for (const { geo, bone } of rigid) {
    const g = geo;
    for (const key of Object.keys(g.attributes)) {
      if (!['position', 'normal', 'color'].includes(key)) g.deleteAttribute(key);
    }
    const n = g.attributes.position.count;
    // Some primitives (rounded boxes) come unindexed; merging needs an index.
    if (!g.index) g.setIndex(Array.from({ length: n }, (_, i) => i));
    const si = new Uint16Array(n * 4), sw = new Float32Array(n * 4);
    for (let i = 0; i < n; i++) {
      si[i * 4] = index[bone];
      sw[i * 4] = 1;
    }
    g.setAttribute('skinIndex', new THREE.BufferAttribute(si, 4));
    g.setAttribute('skinWeight', new THREE.BufferAttribute(sw, 4));
    g.setAttribute('_skin', new THREE.BufferAttribute(new Float32Array(n), 1));
    meshes.push(g);
  }

  const geometry = mergeGeometries(meshes);
  // Two materials: matte cloth and gear, and skin with a soft sheen.
  const flag = geometry.attributes._skin;
  const src = geometry.index.array;
  const cloth = [], skin = [];
  for (let i = 0; i < src.length; i += 3) {
    const k = flag.getX(src[i]) + flag.getX(src[i + 1]) + flag.getX(src[i + 2]);
    (k >= 2 ? skin : cloth).push(src[i], src[i + 1], src[i + 2]);
  }
  geometry.setIndex([...cloth, ...skin]);
  geometry.clearGroups();
  geometry.addGroup(0, cloth.length, 0);
  geometry.addGroup(cloth.length, skin.length, 1);
  geometry.deleteAttribute('_skin');
  const materials = [
    new THREE.MeshStandardMaterial({ name: 'Cloth', vertexColors: true, roughness: 0.92, metalness: 0 }),
    new THREE.MeshStandardMaterial({ name: 'Skin', vertexColors: true, roughness: 0.55, metalness: 0 }),
  ];
  const mesh = new THREE.SkinnedMesh(geometry, materials);
  mesh.name = 'SoldierMesh';
  mesh.castShadow = true;
  mesh.receiveShadow = true;

  const socket = new THREE.Object3D();
  socket.name = 'RightHandSocket';
  socket.position.set(0, -0.07, 0.01);
  bones.RightHand.add(socket);

  const root = new THREE.Group();
  root.name = 'Soldier';
  root.add(bones.Hips);
  root.add(mesh);
  mesh.bind(new THREE.Skeleton(list));
  root.animations = createHumanAnimations();
  return root;
}
