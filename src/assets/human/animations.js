import * as THREE from 'three';

// Animation clips for the realistic soldier. Locomotion follows measured
// human gait: joint angle curves over the stride for hip, knee, ankle and toe,
// plus pelvis rotation/drop, a vertical bob twice per stride, counter-rotating
// shoulders and opposite arm swing.
//
// Conventions (bones hang along -Y, face +Z):
//   UpLeg x < 0 swings the leg forward (hip flexion)
//   Leg x > 0 bends the knee
//   Foot x < 0 lifts the toes (dorsiflexion); ToeBase x < 0 bends the toes up
//   Arm x < 0 swings the arm forward; ForeArm x < 0 bends the elbow

const deg = THREE.MathUtils.degToRad;

// Rest rotations of the rig (degrees), added to every animated value.
const REST = {
  LeftArm: [0, 0, 8], RightArm: [0, 0, -8],
  LeftForeArm: [-10, 0, 0], RightForeArm: [-10, 0, 0],
};

// Periodic Catmull-Rom curve through keys at evenly spaced stride fractions.
function curve(keys) {
  const n = keys.length;
  return (t) => {
    const x = (((t % 1) + 1) % 1) * n;
    const i = Math.floor(x), f = x - i;
    const p0 = keys[(i - 1 + n) % n], p1 = keys[i % n], p2 = keys[(i + 1) % n], p3 = keys[(i + 2) % n];
    return 0.5 * (2 * p1 + (-p0 + p2) * f + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f * f + (-p0 + 3 * p1 - 3 * p2 + p3) * f * f * f);
  };
}

const SAMPLES = 24;

// A rotation track sampled from fn(t in 0..1) -> [x, y, z] degrees.
function rot(bone, duration, fn) {
  const times = [], values = [];
  const q = new THREE.Quaternion();
  const rest = REST[bone] ?? [0, 0, 0];
  for (let i = 0; i <= SAMPLES; i++) {
    const t = i / SAMPLES;
    const [x, y, z] = fn(t);
    q.setFromEuler(new THREE.Euler(deg(rest[0] + x), deg(rest[1] + y), deg(rest[2] + z)));
    times.push(t * duration);
    values.push(q.x, q.y, q.z, q.w);
  }
  return new THREE.QuaternionKeyframeTrack(`${bone}.quaternion`, times, values);
}

function hipsPosition(duration, fn) {
  const times = [], values = [];
  for (let i = 0; i <= SAMPLES; i++) {
    const t = i / SAMPLES;
    times.push(t * duration);
    values.push(...fn(t));
  }
  return new THREE.VectorKeyframeTrack('Hips.position', times, values);
}

const hold = (bone, duration, angles, breathe = [0, 0, 0]) =>
  rot(bone, duration, (t) => angles.map((a, i) => a + breathe[i] * Math.sin(t * Math.PI * 2)));

const sin = (t, k = 1, phase = 0) => Math.sin((t * k + phase) * Math.PI * 2);
const cos = (t, k = 1, phase = 0) => Math.cos((t * k + phase) * Math.PI * 2);

/** Legs, pelvis and spine for one gait; arms are added separately. */
function gait(duration, g) {
  const hip = curve(g.hip), knee = curve(g.knee), ankle = curve(g.ankle), toe = curve(g.toe);
  const tracks = [];
  for (const [side, phase] of [['Left', 0], ['Right', 0.5]]) {
    const s = side === 'Left' ? 1 : -1;
    tracks.push(
      rot(`${side}UpLeg`, duration, (t) => [-hip(t + phase), 0, s * g.hipAbduct]),
      rot(`${side}Leg`, duration, (t) => [knee(t + phase), 0, 0]),
      rot(`${side}Foot`, duration, (t) => [-ankle(t + phase), 0, 0]),
      rot(`${side}ToeBase`, duration, (t) => [-toe(t + phase), 0, 0]),
    );
  }
  tracks.push(
    // Pelvis turns toward the forward leg and drops on the swing side.
    rot('Hips', duration, (t) => [g.lean * 0.3, g.pelvisTurn * sin(t, 1, 0.25), g.pelvisDrop * sin(t, 1)]),
    rot('Spine', duration, (t) => [g.lean * 0.4, -g.pelvisTurn * 0.6 * sin(t, 1, 0.25), -g.pelvisDrop * 0.5 * sin(t, 1)]),
    rot('Chest', duration, (t) => [g.lean * 0.3, -g.shoulderTurn * sin(t, 1, 0.25), 0]),
    rot('Neck', duration, (t) => [-g.lean * 0.3, g.shoulderTurn * 0.4 * sin(t, 1, 0.25), 0]),
    rot('Head', duration, (t) => [-g.lean * 0.4 + 1.5 * sin(t, 2), g.shoulderTurn * 0.4 * sin(t, 1, 0.25), 0]),
    // Body is lowest at foot contact and highest mid-stance (or mid-flight).
    hipsPosition(duration, (t) => [0, g.hipsHeight + g.bob * (0.5 - 0.5 * cos(t, 2, g.bobPhase)), 0]),
  );
  return tracks;
}

function armSwing(duration, a) {
  const tracks = [];
  for (const [side, sign] of [['Left', 1], ['Right', -1]]) {
    // The left arm swings forward with the right leg (and vice versa).
    const swing = (t) => sign * a.swing * cos(t);
    tracks.push(
      rot(`${side}Arm`, duration, (t) => [swing(t) + a.forward, sign * a.across * Math.max(0, -swing(t) / a.swing), sign * a.out]),
      rot(`${side}ForeArm`, duration, (t) => [-(a.elbow + a.elbowSwing * Math.max(0, -swing(t)) / a.swing), 0, 0]),
      rot(`${side}Hand`, duration, () => [a.wrist, 0, 0]),
    );
  }
  return tracks;
}

const WALK = {
  // Stride fractions 0, 1/8, ... 7/8; left heel strikes at 0.
  hip: [28, 22, 12, 0, -10, -2, 18, 28],
  knee: [4, 16, 8, 4, 22, 58, 50, 18],
  ankle: [0, -6, 4, 9, -8, -10, 2, 2],
  toe: [0, 0, 0, 6, 26, 6, 0, 0],
  hipAbduct: 1.5,
  lean: 3,
  pelvisTurn: 5,
  pelvisDrop: 3,
  shoulderTurn: 6,
  hipsHeight: 0.955,
  bob: 0.024,
  bobPhase: 0.5,
};

const RUN = {
  hip: [36, 26, 8, -12, -6, 26, 52, 46],
  knee: [22, 38, 22, 18, 62, 102, 86, 40],
  ankle: [6, 14, 12, -22, -12, 6, 10, 8],
  toe: [0, 0, 8, 28, 4, 0, 0, 0],
  hipAbduct: 1,
  lean: 10,
  pelvisTurn: 7,
  pelvisDrop: 4,
  shoulderTurn: 10,
  hipsHeight: 0.905,
  bob: 0.055,
  bobPhase: 0.0,
};

export function createHumanAnimations() {
  const walkT = 1.1, runT = 0.72;

  const idle = new THREE.AnimationClip('Idle', 4, [
    hold('Hips', 4, [0, 0, 0], [0, 0, 1.2]),
    hold('Spine', 4, [1, 0, 0], [0.8, 0, -0.8]),
    hold('Chest', 4, [0, 0, 0], [1.4, 0, 0]),
    rot('Head', 4, (t) => [2, 6 * sin(t, 1, 0.1), 0]),
    hold('LeftArm', 4, [2, 0, 2], [1.5, 0, 1]),
    hold('RightArm', 4, [2, 0, -2], [1.5, 0, -1]),
    hold('LeftForeArm', 4, [-6, 0, 0]),
    hold('RightForeArm', 4, [-6, 0, 0]),
    hold('LeftUpLeg', 4, [-2, 0, 2]),
    hold('RightUpLeg', 4, [-1, 0, -3]),
    hold('LeftLeg', 4, [5, 0, 0]),
    hold('RightLeg', 4, [3, 0, 0]),
    hold('LeftFoot', 4, [-3, 0, 0]),
    hold('RightFoot', 4, [-2, 0, 0]),
    hipsPosition(4, (t) => [0.006 * sin(t), 0.972 + 0.002 * sin(t, 2), 0]),
  ]);

  const walk = new THREE.AnimationClip('Walk', walkT, [
    ...gait(walkT, WALK),
    ...armSwing(walkT, { swing: 16, forward: 2, across: 3, out: 2, elbow: 12, elbowSwing: 14, wrist: 0 }),
  ]);
  const run = new THREE.AnimationClip('Run', runT, [
    ...gait(runT, RUN),
    ...armSwing(runT, { swing: 38, forward: -4, across: 14, out: 6, elbow: 80, elbowSwing: 18, wrist: -6 }),
  ]);

  // Rifle shouldered: right hand on the grip, left hand on the handguard.
  const aimArms = (d) => [
    hold('RightArm', d, [-35, 0, 30], [-1, 0, 0]),
    hold('RightForeArm', d, [-95, 0, 0]),
    hold('LeftArm', d, [-76, 0, -24], [-1, 0, 0]),
    hold('LeftForeArm', d, [-14, 0, 0]),
    hold('Chest', d, [3, 0, 0], [0.6, 0, 0]),
    hold('Neck', d, [2, 0, 0]),
    hold('Head', d, [3, 0, 0]),
  ];
  const aim = new THREE.AnimationClip('Aim', 3, [
    ...aimArms(3),
    hold('LeftUpLeg', 3, [-9, 0, 4]),
    hold('RightUpLeg', 3, [5, 0, -4]),
    hold('LeftLeg', 3, [10, 0, 0]),
    hold('RightLeg', 3, [8, 0, 0]),
    hold('LeftFoot', 3, [-2, 0, 0]),
    hold('RightFoot', 3, [-6, 0, 0]),
    hipsPosition(3, (t) => [0, 0.962 + 0.002 * sin(t), 0]),
  ]);

  // Moving with a gun up: legs from the gait, upper body from Aim.
  const UPPER = /^(LeftArm|RightArm|LeftForeArm|RightForeArm|LeftHand|RightHand|Chest|Neck|Head)\./;
  const withAim = (name, base) => new THREE.AnimationClip(name, base.duration, [
    ...base.tracks.filter((t) => !UPPER.test(t.name)),
    ...aimArms(base.duration),
  ]);

  const skydive = new THREE.AnimationClip('Skydive', 1, [
    hold('LeftArm', 1, [-10, 0, 80], [-2, 0, 3]),
    hold('RightArm', 1, [-10, 0, -80], [-2, 0, -3]),
    hold('LeftForeArm', 1, [-35, 0, 0], [-3, 0, 0]),
    hold('RightForeArm', 1, [-35, 0, 0], [-3, 0, 0]),
    hold('LeftUpLeg', 1, [12, 0, 8], [2, 0, 0]),
    hold('RightUpLeg', 1, [12, 0, -8], [2, 0, 0]),
    hold('LeftLeg', 1, [48, 0, 0], [3, 0, 0]),
    hold('RightLeg', 1, [48, 0, 0], [3, 0, 0]),
    hold('Neck', 1, [-15, 0, 0]),
    hold('Head', 1, [-20, 0, 0]),
  ]);
  const parachute = new THREE.AnimationClip('Parachute', 2, [
    hold('LeftArm', 2, [-15, 0, 155], [-2, 0, -2]),
    hold('RightArm', 2, [-15, 0, -155], [-2, 0, 2]),
    hold('LeftForeArm', 2, [-25, 0, 0]),
    hold('RightForeArm', 2, [-25, 0, 0]),
    rot('LeftUpLeg', 2, (t) => [-6 + 4 * sin(t), 0, 3]),
    rot('RightUpLeg', 2, (t) => [-6 - 4 * sin(t), 0, -3]),
    hold('LeftLeg', 2, [14, 0, 0], [3, 0, 0]),
    hold('RightLeg', 2, [14, 0, 0], [-3, 0, 0]),
    hold('LeftFoot', 2, [12, 0, 0]),
    hold('RightFoot', 2, [12, 0, 0]),
  ]);

  return [idle, walk, run, aim, withAim('WalkAim', walk), withAim('RunAim', run), skydive, parachute];
}
