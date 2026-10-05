import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';

// Realistic-proportioned soldier (~1.80 m, feet at y = 0, facing +Z).
// Built as a joint hierarchy with Mixamo-style names (Hips, Spine, LeftArm...)
// so it can be animated in Three.js and, once exported to GLB, in Flutter.
// Weapons attach to the empty "RightHandSocket" node.

const deg = THREE.MathUtils.degToRad;

function mesh(name, geometry, material, castShadow = true) {
  const m = new THREE.Mesh(geometry, material);
  m.name = name;
  m.castShadow = castShadow;
  m.receiveShadow = true;
  return m;
}

function joint(name, x, y, z) {
  const g = new THREE.Group();
  g.name = name;
  g.position.set(x, y, z);
  return g;
}

// Smooth, muscle-shaped limb segment hanging down -Y from its joint.
// radii: list of radius values sampled evenly from top (joint) to bottom.
function limbGeometry(length, radii, depthScale = 1, radial = 24) {
  const pts = [];
  pts.push(new THREE.Vector2(0.0001, 0));
  radii.forEach((r, i) => {
    const t = i / (radii.length - 1);
    pts.push(new THREE.Vector2(r, -t * length));
  });
  pts.push(new THREE.Vector2(0.0001, -length));
  const curve = new THREE.SplineCurve(pts.slice(1, -1));
  const smooth = [pts[0], ...curve.getPoints(radii.length * 4), pts[pts.length - 1]];
  const geo = new THREE.LatheGeometry(smooth, radial);
  geo.scale(1, 1, depthScale);
  return geo;
}

// Torso section going up +Y from its joint (radius profile bottom -> top).
function torsoGeometry(height, radii, depthScale) {
  const pts = radii.map((r, i) => new THREE.Vector2(r, (i / (radii.length - 1)) * height));
  const curve = new THREE.SplineCurve(pts);
  const smooth = curve.getPoints(radii.length * 5);
  smooth.unshift(new THREE.Vector2(0.0001, 0));
  smooth.push(new THREE.Vector2(0.0001, height));
  const geo = new THREE.LatheGeometry(smooth, 32);
  geo.scale(1, 1, depthScale);
  return geo;
}

function headGeometry() {
  const geo = new THREE.SphereGeometry(0.1, 48, 36);
  const p = geo.attributes.position;
  const v = new THREE.Vector3();
  for (let i = 0; i < p.count; i++) {
    v.fromBufferAttribute(p, i);
    const ny = v.y / 0.1; // -1 (chin) .. 1 (crown)
    v.y *= 1.13;
    v.z *= 1.08;
    if (ny < 0) {
      // Narrow toward the jaw and chin.
      const k = 1 - 0.2 * Math.pow(-ny, 1.6);
      v.x *= k;
      if (v.z < 0) v.z *= 0.9 + 0.1 * (1 + ny);
    }
    // Flatten the back of the skull a little and the face front.
    if (v.z > 0.07) v.z = 0.07 + (v.z - 0.07) * 0.6;
    // Temples slightly narrower than cheekbones.
    if (ny > 0.2) v.x *= 1 - 0.06 * (ny - 0.2);
    p.setXYZ(i, v.x, v.y, v.z);
  }
  geo.computeVertexNormals();
  return geo;
}

function buildHead(mats) {
  const neck = joint('Neck', 0, 0.2, 0);
  neck.add(mesh('NeckMesh', limbGeometry(0.11, [0.052, 0.055, 0.06], 1.0), mats.skin));
  neck.children[0].rotation.x = Math.PI; // grow upward
  neck.children[0].position.y = 0;

  const head = joint('Head', 0, 0.1, 0.005);
  neck.add(head);
  const skull = mesh('HeadMesh', headGeometry(), mats.skin);
  skull.position.y = 0.1;
  head.add(skull);

  // Hair: upper shell of a slightly larger head.
  const hairGeo = new THREE.SphereGeometry(0.106, 40, 20, 0, Math.PI * 2, 0, Math.PI * 0.52);
  hairGeo.scale(1, 1.14, 1.1);
  const hair = mesh('Hair', hairGeo, mats.hair);
  hair.position.set(0, 0.113, -0.006);
  hair.rotation.x = deg(-12);
  head.add(hair);

  // Eyes
  for (const s of [-1, 1]) {
    const side = s < 0 ? 'Right' : 'Left';
    const eye = mesh(`${side}Eye`, new THREE.SphereGeometry(0.0125, 16, 12), mats.eyeWhite, false);
    eye.position.set(0.034 * s, 0.108, 0.08);
    head.add(eye);
    const iris = mesh(`${side}Iris`, new THREE.SphereGeometry(0.0065, 12, 8), mats.iris, false);
    iris.position.set(0.034 * s, 0.108, 0.0915);
    head.add(iris);
    const brow = mesh(`${side}Brow`, new RoundedBoxGeometry(0.034, 0.006, 0.012, 2, 0.003), mats.hair, false);
    brow.position.set(0.034 * s, 0.126, 0.09);
    brow.rotation.z = deg(-6 * s);
    head.add(brow);
    const ear = mesh(`${side}Ear`, new THREE.SphereGeometry(0.022, 16, 12), mats.skin);
    ear.scale.set(0.4, 1.15, 0.75);
    ear.position.set(0.1 * s, 0.1, -0.005);
    head.add(ear);
  }

  // Nose: a tapered wedge.
  const noseGeo = new THREE.ConeGeometry(0.014, 0.045, 4, 1);
  noseGeo.rotateY(Math.PI / 4);
  noseGeo.scale(1, 1, 0.9);
  const nose = mesh('Nose', noseGeo, mats.skin);
  nose.position.set(0, 0.088, 0.095);
  nose.rotation.x = deg(-18);
  head.add(nose);
  const nostrils = mesh('NoseTip', new THREE.SphereGeometry(0.012, 16, 10), mats.skin);
  nostrils.scale.set(1.3, 0.8, 0.9);
  nostrils.position.set(0, 0.07, 0.1);
  head.add(nostrils);

  // Mouth
  const lipsGeo = new THREE.CapsuleGeometry(0.0055, 0.03, 4, 12);
  lipsGeo.rotateZ(Math.PI / 2);
  const lips = mesh('Lips', lipsGeo, mats.lips, false);
  lips.scale.set(1, 1, 0.6);
  lips.position.set(0, 0.048, 0.092);
  head.add(lips);

  return neck;
}

function buildHand(mats, s) {
  const side = s < 0 ? 'Right' : 'Left';
  const hand = joint(`${side}Hand`, 0, -0.255, 0);
  const palm = mesh(`${side}Palm`, new RoundedBoxGeometry(0.03, 0.09, 0.08, 3, 0.012), mats.glove);
  palm.position.y = -0.045;
  hand.add(palm);
  // Four fingers, slightly curled.
  for (let i = 0; i < 4; i++) {
    const len = [0.07, 0.078, 0.074, 0.06][i];
    const f = mesh(`${side}Finger${i}`, new THREE.CapsuleGeometry(0.0085, len - 0.017, 4, 8), mats.glove);
    f.position.set(0, -0.09 - len / 2 + 0.008, 0.028 - i * 0.019);
    f.rotation.x = deg(-8);
    f.rotation.z = deg(10 * s);
    hand.add(f);
  }
  const thumb = mesh(`${side}Thumb`, new THREE.CapsuleGeometry(0.01, 0.045, 4, 8), mats.glove);
  thumb.position.set(0.012 * s * -1, -0.05, 0.048);
  thumb.rotation.set(deg(35), 0, deg(-20 * s));
  hand.add(thumb);
  return hand;
}

function buildArm(mats, s) {
  const side = s < 0 ? 'Right' : 'Left';
  const shoulder = joint(`${side}Shoulder`, 0.07 * s, 0.2, -0.005);
  const arm = joint(`${side}Arm`, 0.1 * s, -0.005, 0);
  shoulder.add(arm);
  arm.rotation.z = deg(8 * s); // relaxed A-pose

  // Deltoid cap
  const delt = mesh(`${side}Deltoid`, new THREE.SphereGeometry(0.056, 24, 16), mats.shirt);
  delt.scale.set(0.95, 0.85, 1.0);
  delt.position.set(-0.008 * s, -0.005, 0);
  arm.add(delt);
  arm.add(mesh(`${side}UpperArm`, limbGeometry(0.29, [0.054, 0.056, 0.05, 0.044, 0.041], 1.0), mats.shirt));

  const fore = joint(`${side}ForeArm`, 0, -0.29, 0);
  arm.add(fore);
  fore.rotation.x = deg(-10);
  // Rolled sleeve + bare forearm
  const sleeve = mesh(`${side}Cuff`, new THREE.TorusGeometry(0.043, 0.012, 10, 24), mats.shirt);
  sleeve.rotation.x = Math.PI / 2;
  sleeve.position.y = -0.03;
  fore.add(sleeve);
  fore.add(mesh(`${side}ForeArmMesh`, limbGeometry(0.255, [0.042, 0.045, 0.04, 0.032, 0.027], 0.85), mats.skin));
  const hand = buildHand(mats, s);
  fore.add(hand);
  if (s < 0) {
    const socket = joint('RightHandSocket', 0, -0.07, 0.01);
    hand.add(socket);
  }
  return shoulder;
}

function buildLeg(mats, s) {
  const side = s < 0 ? 'Right' : 'Left';
  const up = joint(`${side}UpLeg`, 0.095 * s, -0.04, 0);
  up.add(mesh(`${side}Thigh`, limbGeometry(0.44, [0.085, 0.088, 0.078, 0.066, 0.055], 1.05), mats.pants));
  // Cargo pocket on thigh
  const pocket = mesh(`${side}CargoPocket`, new RoundedBoxGeometry(0.03, 0.12, 0.11, 2, 0.01), mats.pants);
  pocket.position.set(0.075 * s, -0.22, 0);
  up.add(pocket);

  const leg = joint(`${side}Leg`, 0, -0.44, 0);
  up.add(leg);
  leg.add(mesh(`${side}Shin`, limbGeometry(0.43, [0.056, 0.06, 0.055, 0.045, 0.042], 1.05), mats.pants));
  const pad = mesh(`${side}KneePad`, new RoundedBoxGeometry(0.09, 0.11, 0.04, 3, 0.015), mats.strap);
  pad.position.set(0, -0.02, 0.055);
  leg.add(pad);

  const foot = joint(`${side}Foot`, 0, -0.43, 0);
  leg.add(foot);
  const shaft = mesh(`${side}BootShaft`, limbGeometry(0.1, [0.05, 0.052, 0.054], 1.05), mats.boot);
  shaft.position.y = 0.06;
  foot.add(shaft);
  const boot = mesh(`${side}Boot`, new RoundedBoxGeometry(0.1, 0.085, 0.26, 4, 0.03), mats.boot);
  boot.position.set(0, -0.035, 0.045);
  foot.add(boot);
  const sole = mesh(`${side}Sole`, new RoundedBoxGeometry(0.105, 0.022, 0.27, 2, 0.008), mats.sole);
  sole.position.set(0, -0.075, 0.045);
  foot.add(sole);
  return up;
}

function buildTorso(mats) {
  const spine = joint('Spine', 0, 0.06, 0);
  spine.add(mesh('Abdomen', torsoGeometry(0.2, [0.15, 0.142, 0.145, 0.155], 0.68), mats.shirt));

  const chest = joint('Chest', 0, 0.18, 0);
  spine.add(chest);
  chest.add(mesh('ChestMesh', torsoGeometry(0.25, [0.155, 0.17, 0.18, 0.17, 0.1], 0.66), mats.shirt));

  // Plate-carrier vest
  const vestFront = mesh('VestFront', new RoundedBoxGeometry(0.3, 0.3, 0.06, 4, 0.02), mats.vest);
  vestFront.position.set(0, 0.07, 0.095);
  chest.add(vestFront);
  const vestBack = mesh('VestBack', new RoundedBoxGeometry(0.3, 0.32, 0.05, 4, 0.02), mats.vest);
  vestBack.position.set(0, 0.07, -0.1);
  chest.add(vestBack);
  for (const s of [-1, 1]) {
    const strap = mesh('VestStrap', new RoundedBoxGeometry(0.05, 0.03, 0.22, 2, 0.01), mats.vest);
    strap.position.set(0.1 * s, 0.235, 0);
    chest.add(strap);
    const side = mesh('VestSide', new RoundedBoxGeometry(0.03, 0.14, 0.18, 2, 0.01), mats.vest);
    side.position.set(0.155 * s, 0.02, 0);
    chest.add(side);
  }
  // Magazine pouches
  for (let i = 0; i < 3; i++) {
    const p = mesh(`MagPouch${i}`, new RoundedBoxGeometry(0.075, 0.1, 0.04, 3, 0.01), mats.pouch);
    p.position.set((i - 1) * 0.085, -0.01, 0.14);
    chest.add(p);
    const flap = mesh(`MagFlap${i}`, new RoundedBoxGeometry(0.077, 0.03, 0.045, 2, 0.008), mats.strap);
    flap.position.set((i - 1) * 0.085, 0.04, 0.142);
    chest.add(flap);
  }
  const radio = mesh('RadioPouch', new RoundedBoxGeometry(0.06, 0.08, 0.04, 3, 0.01), mats.pouch);
  radio.position.set(0.095, 0.13, 0.135);
  chest.add(radio);
  const antenna = mesh('Antenna', new THREE.CylinderGeometry(0.003, 0.004, 0.14, 6), mats.strap);
  antenna.position.set(0.115, 0.21, 0.135);
  chest.add(antenna);

  chest.add(buildHead(mats));
  chest.add(buildArm(mats, 1));
  chest.add(buildArm(mats, -1));
  return spine;
}

function buildHips(mats) {
  const hips = joint('Hips', 0, 0.98, 0);
  const pelvis = mesh('Pelvis', torsoGeometry(0.14, [0.13, 0.16, 0.155, 0.15], 0.72), mats.pants);
  pelvis.position.y = -0.08;
  hips.add(pelvis);
  // Belt + buckle + holster
  const belt = mesh('Belt', new THREE.TorusGeometry(0.155, 0.018, 8, 40), mats.strap);
  belt.rotation.x = Math.PI / 2;
  belt.scale.set(1, 0.72, 1.4);
  belt.position.y = 0.03;
  hips.add(belt);
  const buckle = mesh('Buckle', new RoundedBoxGeometry(0.05, 0.035, 0.012, 2, 0.004), mats.buckle);
  buckle.position.set(0, 0.03, 0.115);
  hips.add(buckle);
  const holster = mesh('Holster', new RoundedBoxGeometry(0.045, 0.16, 0.08, 3, 0.012), mats.strap);
  holster.position.set(-0.17, -0.06, 0.01);
  hips.add(holster);

  hips.add(buildTorso(mats));
  hips.add(buildLeg(mats, 1));
  hips.add(buildLeg(mats, -1));
  return hips;
}

// ---------------------------------------------------------------- animations

function quatTrack(node, times, eulers) {
  const values = [];
  const q = new THREE.Quaternion();
  for (const [x, y, z] of eulers) {
    q.setFromEuler(new THREE.Euler(deg(x), deg(y), deg(z)));
    values.push(q.x, q.y, q.z, q.w);
  }
  return new THREE.QuaternionKeyframeTrack(`${node}.quaternion`, times, values);
}

// Rest rotations so animated joints keep their base pose.
const REST = {
  LeftArm: [0, 0, 8], RightArm: [0, 0, -8],
  LeftForeArm: [-10, 0, 0], RightForeArm: [-10, 0, 0],
};

function cycle(node, period, swing, axis = 0, phase = 0, bias = 0) {
  const steps = 8;
  const times = [];
  const eulers = [];
  const rest = REST[node] || [0, 0, 0];
  for (let i = 0; i <= steps; i++) {
    const t = (i / steps) * period;
    const a = bias + swing * Math.sin((i / steps) * Math.PI * 2 + phase);
    const e = [...rest];
    e[axis] += a;
    times.push(t);
    eulers.push(e);
  }
  return quatTrack(node, times, eulers);
}

function hipsBob(period, height, base = 0.98) {
  const times = [], values = [];
  for (let i = 0; i <= 8; i++) {
    times.push((i / 8) * period);
    values.push(0, base + height * Math.abs(Math.sin((i / 8) * Math.PI * 2)), 0);
  }
  return new THREE.VectorKeyframeTrack('Hips.position', times, values);
}

export function createCharacterAnimations() {
  const idle = new THREE.AnimationClip('Idle', 3, [
    cycle('Chest', 3, 1.5, 0),
    cycle('LeftArm', 3, 2, 2, 0),
    cycle('RightArm', 3, -2, 2, 0),
    cycle('Head', 3, 2, 1, 1),
  ]);
  const walk = new THREE.AnimationClip('Walk', 1.1, [
    cycle('LeftUpLeg', 1.1, 28, 0, 0),
    cycle('RightUpLeg', 1.1, 28, 0, Math.PI),
    cycle('LeftLeg', 1.1, 22, 0, -Math.PI / 2, 22),
    cycle('RightLeg', 1.1, 22, 0, Math.PI / 2, 22),
    cycle('LeftArm', 1.1, 22, 0, Math.PI),
    cycle('RightArm', 1.1, 22, 0, 0),
    cycle('Spine', 1.1, 4, 1, 0),
    hipsBob(1.1, 0.025, 0.96),
  ]);
  const run = new THREE.AnimationClip('Run', 0.7, [
    cycle('LeftUpLeg', 0.7, 45, 0, 0, -10),
    cycle('RightUpLeg', 0.7, 45, 0, Math.PI, -10),
    cycle('LeftLeg', 0.7, 45, 0, -Math.PI / 2, 50),
    cycle('RightLeg', 0.7, 45, 0, Math.PI / 2, 50),
    cycle('LeftArm', 0.7, 40, 0, Math.PI),
    cycle('RightArm', 0.7, 40, 0, 0),
    cycle('LeftForeArm', 0.7, 10, 0, 0, -60),
    cycle('RightForeArm', 0.7, 10, 0, 0, -60),
    cycle('Spine', 0.7, 6, 1, 0, 0),
    cycle('Chest', 0.7, 0, 0, 0, 10),
    hipsBob(0.7, 0.05, 0.93),
  ]);
  // Shouldered-rifle pose with a slight breathing sway.
  const hold = (node, a, b) => quatTrack(node, [0, 1.5, 3], [a, b, a]);
  const aim = new THREE.AnimationClip('Aim', 3, [
    hold('RightArm', [-35, 0, 30], [-36, 0, 30]),
    hold('RightForeArm', [-95, 0, 0], [-95, 0, 0]),
    hold('LeftArm', [-76, 0, -24], [-77, 0, -24]),
    hold('LeftForeArm', [-14, 0, 0], [-14, 0, 0]),
    hold('Chest', [3, 0, 0], [4, 0, 0]),
    hold('Head', [4, 0, 0], [4, 0, 0]),
  ]);
  // Move while holding a gun: legs and hips from the locomotion clip, arms,
  // chest and head from Aim (resampled to the locomotion clip's length).
  const AIM_NODES = /^(LeftArm|RightArm|LeftForeArm|RightForeArm|Chest|Head)\./;
  const withAim = (name, base) => new THREE.AnimationClip(name, base.duration, [
    ...base.tracks.filter((t) => !AIM_NODES.test(t.name)),
    ...aim.tracks.map((t) => {
      const track = t.clone();
      track.times = track.times.map((time) => (time / aim.duration) * base.duration);
      return track;
    }),
  ]);
  return [idle, walk, run, aim, withAim('WalkAim', walk), withAim('RunAim', run)];
}

export function createCharacter(mats) {
  const root = new THREE.Group();
  root.name = 'Soldier';
  root.add(buildHips(mats));
  root.animations = createCharacterAnimations();
  return root;
}
