import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';

// Weapons in real-world scale (meters). Convention for every gun:
//   origin = top of the pistol grip (where the right hand holds it),
//   barrel points +Z, top of the gun is +Y.
// A child node named "Muzzle" marks where bullets / muzzle flash spawn,
// and "SupportHand" marks where the left hand should go.

const deg = THREE.MathUtils.degToRad;

// Low detail for guns seen at a distance (bots, loot): plain boxes, coarse
// tubes, no rail teeth. Toggled by withLowDetail().
let LOW = false;
export function withLowDetail(build) {
  return (mats) => {
    LOW = true;
    try {
      return build(mats);
    } finally {
      LOW = false;
    }
  };
}

class GunBuilder {
  constructor(name, mats) {
    this.mats = mats;
    this.root = new THREE.Group();
    this.root.name = name;
  }

  add(name, geometry, material, x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0) {
    const m = new THREE.Mesh(geometry, material);
    m.name = name;
    m.position.set(x, y, z);
    m.rotation.set(rx, ry, rz);
    m.castShadow = true;
    m.receiveShadow = true;
    this.root.add(m);
    return m;
  }

  box(name, w, h, d, material, x, y, z, radius = 0.004, rx = 0) {
    const r = Math.min(radius, w / 2 - 1e-4, h / 2 - 1e-4, d / 2 - 1e-4);
    const geo = LOW ? new THREE.BoxGeometry(w, h, d) : new RoundedBoxGeometry(w, h, d, 2, r);
    return this.add(name, geo, material, x, y, z, rx);
  }

  // Cylinder lying along Z.
  tube(name, radius, length, material, x, y, z, radiusEnd = radius, segments = 20) {
    const geo = new THREE.CylinderGeometry(radiusEnd, radius, length, LOW ? 7 : segments);
    geo.rotateX(Math.PI / 2);
    return this.add(name, geo, material, x, y, z + length / 2);
  }

  marker(name, x, y, z) {
    const g = new THREE.Group();
    g.name = name;
    g.position.set(x, y, z);
    this.root.add(g);
    return g;
  }

  grip(material, angle = 18, h = 0.11) {
    const geo = LOW ? new THREE.BoxGeometry(0.03, h, 0.045) : new RoundedBoxGeometry(0.03, h, 0.045, 3, 0.012);
    geo.translate(0, -h / 2, 0);
    return this.add('Grip', geo, material, 0, 0, 0, deg(-angle));
  }

  triggerGuard(z = 0.04) {
    const guard = new THREE.TorusGeometry(0.022, 0.0035, 6, 20, Math.PI);
    guard.rotateZ(Math.PI);
    guard.rotateY(Math.PI / 2);
    this.add('TriggerGuard', guard, this.mats.polymer, 0, -0.006, z);
    this.box('Trigger', 0.006, 0.02, 0.006, this.mats.darkMetal, 0, -0.012, z, 0.002);
  }

  // Magazine as one extruded side profile, optionally curved forward (AK / M4 style).
  magazine(x, y, z, length, curve = 0, w = 0.026, d = 0.07, material = this.mats.darkMetal) {
    const steps = 10;
    const front = [], back = [];
    for (let i = 0; i <= steps; i++) {
      const t = i / steps;
      const off = curve * t * t;
      front.push(new THREE.Vector2(d / 2 + off, -length * t));
      back.push(new THREE.Vector2(-d / 2 + off, -length * t));
    }
    const shape = new THREE.Shape([...front, ...back.reverse()]);
    const geo = new THREE.ExtrudeGeometry(shape, {
      depth: w - 0.004, bevelEnabled: true, bevelSize: 0.002, bevelThickness: 0.002, bevelSegments: 2,
    });
    geo.rotateY(-Math.PI / 2);
    geo.translate(w / 2 - 0.002, 0, 0);
    this.add('Magazine', geo, material, x, y, z);
    // Base plate
    const end = front[steps];
    this.box('MagBase', w + 0.004, 0.01, d + 0.008, material, x, y - length - 0.004, z + end.x - d / 2, 0.003);
  }

  scope(y, z, length = 0.3, radius = 0.02) {
    const m = this.mats;
    this.tube('ScopeBody', radius, length, m.darkMetal, 0, y, z);
    this.tube('ScopeObjective', radius * 1.1, 0.07, m.darkMetal, 0, y, z + length - 0.03, radius * 1.6);
    this.tube('ScopeEyepiece', radius * 1.4, 0.06, m.darkMetal, 0, y, z - 0.04, radius * 1.15);
    this.add('ScopeLensFront', new THREE.CircleGeometry(radius * 1.45, 24), m.lens, 0, y, z + length + 0.041);
    this.add('ScopeLensRear', new THREE.CircleGeometry(radius * 1.3, 24), m.lens, 0, y, z - 0.041, 0, Math.PI);
    this.add('ScopeTurret', new THREE.CylinderGeometry(0.011, 0.011, 0.025, 16), m.darkMetal, 0, y + radius + 0.01, z + length * 0.45);
    for (const dz of [0.06, length - 0.08]) {
      this.box('ScopeRing', 0.03, radius + 0.012, 0.02, m.darkMetal, 0, y - radius * 0.7, z + dz, 0.003);
    }
  }

  // Picatinny rail with teeth.
  rail(y, z, length) {
    if (LOW) {
      this.box('Rail', 0.022, 0.01, length, this.mats.darkMetal, 0, y, z + length / 2);
      return;
    }
    this.box('Rail', 0.022, 0.008, length, this.mats.darkMetal, 0, y, z + length / 2, 0.002);
    const n = Math.floor(length / 0.01);
    const teeth = [];
    for (let i = 0; i < n; i += 2) {
      const g = new THREE.BoxGeometry(0.024, 0.004, 0.005);
      g.translate(0, y + 0.006, z + i * 0.01 + 0.005);
      teeth.push(g);
    }
    if (teeth.length) {
      const merged = mergeGeometries(teeth);
      this.add('RailTeeth', merged, this.mats.darkMetal);
    }
  }
}

export function createPistol(mats) {
  const b = new GunBuilder('Pistol', mats);
  b.grip(mats.polymer, 15, 0.1);
  b.box('Frame', 0.028, 0.03, 0.16, mats.polymer, 0, 0.005, 0.045, 0.006);
  b.box('Slide', 0.026, 0.032, 0.19, mats.gunMetal, 0, 0.034, 0.05, 0.004);
  // Slide serrations
  for (let i = 0; i < 6; i++) {
    b.box('Serration', 0.027, 0.022, 0.003, mats.darkMetal, 0, 0.034, -0.03 + i * 0.007, 0.001);
  }
  b.tube('Barrel', 0.0065, 0.012, mats.darkMetal, 0, 0.036, 0.145);
  b.box('FrontSight', 0.004, 0.007, 0.006, mats.darkMetal, 0, 0.053, 0.13, 0.001);
  b.box('RearSight', 0.02, 0.007, 0.006, mats.darkMetal, 0, 0.053, -0.035, 0.001);
  b.box('Magwell', 0.024, 0.012, 0.035, mats.darkMetal, 0, -0.105, -0.03, 0.003);
  b.triggerGuard(0.035);
  b.marker('Muzzle', 0, 0.036, 0.16);
  b.root.userData = { type: 'pistol', damage: 25, fireRate: 4, magazine: 15 };
  return b.root;
}

export function createAssaultRifle(mats) {
  const b = new GunBuilder('AssaultRifle', mats);
  b.grip(mats.polymer, 20, 0.105);
  b.box('LowerReceiver', 0.032, 0.05, 0.2, mats.gunMetal, 0, 0.0, 0.06, 0.005);
  b.box('UpperReceiver', 0.034, 0.045, 0.22, mats.gunMetal, 0, 0.045, 0.07, 0.005);
  b.box('EjectionPort', 0.003, 0.016, 0.05, mats.darkMetal, 0.017, 0.045, 0.08, 0.001);
  b.box('ChargingHandle', 0.03, 0.01, 0.03, mats.darkMetal, 0, 0.07, -0.03, 0.002);
  b.rail(0.068, -0.04, 0.43);
  // Handguard with vent slots
  b.box('Handguard', 0.044, 0.05, 0.3, mats.polymer, 0, 0.04, 0.33, 0.01);
  for (let i = 0; i < 6; i++) {
    for (const s of [-1, 1]) {
      b.box('Vent', 0.002, 0.012, 0.03, mats.darkMetal, 0.0225 * s, 0.04, 0.215 + i * 0.045, 0.001);
    }
  }
  b.tube('Barrel', 0.0085, 0.18, mats.darkMetal, 0, 0.04, 0.48);
  b.tube('GasBlock', 0.014, 0.025, mats.darkMetal, 0, 0.04, 0.5);
  b.tube('FlashHider', 0.012, 0.05, mats.darkMetal, 0, 0.04, 0.66, 0.011, 8);
  b.box('FrontSightPost', 0.006, 0.05, 0.015, mats.darkMetal, 0, 0.088, 0.5, 0.002);
  // Buffer tube + adjustable stock
  b.tube('BufferTube', 0.016, 0.2, mats.darkMetal, 0, 0.035, -0.24);
  b.box('Stock', 0.04, 0.085, 0.17, mats.polymer, 0, 0.015, -0.27, 0.012);
  b.box('ButtPad', 0.042, 0.11, 0.02, mats.strap, 0, 0.005, -0.36, 0.006);
  b.magazine(0, -0.022, 0.1, 0.17, 0.05);
  b.box('RedDotBody', 0.03, 0.035, 0.06, mats.darkMetal, 0, 0.09, 0.04, 0.006);
  b.add('RedDotLens', new THREE.CircleGeometry(0.011, 20), mats.redDot, 0, 0.093, 0.071);
  b.triggerGuard(0.035);
  b.box('ForeGrip', 0.03, 0.08, 0.035, mats.polymer, 0, -0.025, 0.36, 0.012);
  b.marker('Muzzle', 0, 0.04, 0.71);
  b.marker('SupportHand', 0, -0.03, 0.36);
  b.root.userData = { type: 'assault_rifle', damage: 30, fireRate: 10, magazine: 30 };
  return b.root;
}

export function createSniperRifle(mats) {
  const b = new GunBuilder('SniperRifle', mats);
  // One-piece tan chassis stock
  b.grip(mats.tan, 12, 0.11);
  b.box('Chassis', 0.045, 0.06, 0.55, mats.tan, 0, 0.0, 0.17, 0.012);
  b.box('StockComb', 0.04, 0.035, 0.24, mats.tan, 0, 0.04, -0.2, 0.012);
  b.box('StockButt', 0.045, 0.13, 0.27, mats.tan, 0, -0.015, -0.26, 0.015);
  b.box('ButtPad', 0.047, 0.14, 0.025, mats.strap, 0, -0.015, -0.4, 0.008);
  b.box('Receiver', 0.035, 0.035, 0.24, mats.gunMetal, 0, 0.045, 0.06, 0.008);
  // Bolt handle
  b.tube('BoltBody', 0.009, 0.08, mats.gunMetal, 0, 0.048, -0.04);
  const handle = new THREE.CylinderGeometry(0.004, 0.004, 0.06, 8);
  handle.rotateZ(Math.PI / 2);
  b.add('BoltHandle', handle, mats.gunMetal, 0.04, 0.045, -0.02, 0, 0, deg(-25));
  b.add('BoltKnob', new THREE.SphereGeometry(0.009, 12, 10), mats.gunMetal, 0.07, 0.03, -0.02);
  b.tube('Barrel', 0.011, 0.6, mats.gunMetal, 0, 0.045, 0.18, 0.009);
  b.tube('MuzzleBrake', 0.014, 0.06, mats.darkMetal, 0, 0.045, 0.78);
  b.scope(0.105, -0.07, 0.32, 0.019);
  b.magazine(0, -0.025, 0.06, 0.06, 0, 0.03, 0.08);
  b.triggerGuard(0.04);
  // Folded bipod
  for (const s of [-1, 1]) {
    b.tube('BipodLeg', 0.005, 0.18, mats.darkMetal, 0.015 * s, -0.035, 0.27);
  }
  b.marker('Muzzle', 0, 0.045, 0.84);
  b.marker('SupportHand', 0, -0.03, 0.28);
  b.root.userData = { type: 'sniper_rifle', damage: 90, fireRate: 0.8, magazine: 5 };
  return b.root;
}

export function createMachineGun(mats) {
  const b = new GunBuilder('MachineGun', mats);
  b.grip(mats.polymer, 20, 0.11);
  b.box('Receiver', 0.06, 0.09, 0.36, mats.gunMetal, 0, 0.03, 0.08, 0.008);
  b.box('FeedCover', 0.064, 0.025, 0.2, mats.darkMetal, 0, 0.085, 0.02, 0.006);
  // Carry handle
  b.box('HandleBase', 0.015, 0.035, 0.015, mats.darkMetal, 0, 0.115, 0.27, 0.003);
  b.box('HandleBase2', 0.015, 0.035, 0.015, mats.darkMetal, 0, 0.115, 0.37, 0.003);
  b.box('CarryHandle', 0.02, 0.015, 0.13, mats.polymer, 0, 0.135, 0.32, 0.006);
  b.box('Handguard', 0.065, 0.06, 0.26, mats.polymer, 0, 0.02, 0.38, 0.012);
  for (let i = 0; i < 5; i++) {
    b.box('Rib', 0.067, 0.008, 0.012, mats.darkMetal, 0, 0.05, 0.28 + i * 0.045, 0.002);
  }
  b.tube('Barrel', 0.013, 0.45, mats.darkMetal, 0, 0.03, 0.5);
  b.tube('BarrelShroudRing', 0.019, 0.02, mats.darkMetal, 0, 0.03, 0.55);
  b.tube('GasTube', 0.008, 0.25, mats.darkMetal, 0, -0.005, 0.5);
  b.tube('FlashHider', 0.016, 0.07, mats.darkMetal, 0, 0.03, 0.93, 0.014, 6);
  b.box('FrontSight', 0.008, 0.05, 0.015, mats.darkMetal, 0, 0.06, 0.88, 0.002);
  // Skeleton stock
  b.box('StockTop', 0.04, 0.03, 0.28, mats.polymer, 0, 0.05, -0.22, 0.01);
  b.box('StockBottom', 0.04, 0.03, 0.26, mats.polymer, 0, -0.04, -0.23, 0.01, deg(8));
  b.box('ButtPlate', 0.045, 0.14, 0.03, mats.strap, 0, 0.0, -0.37, 0.008);
  // 200-round box magazine on the left side
  b.box('AmmoBox', 0.1, 0.12, 0.12, mats.tan, -0.075, -0.055, 0.08, 0.01);
  b.box('AmmoBoxLid', 0.104, 0.015, 0.124, mats.polymer, -0.075, 0.008, 0.08, 0.004);
  // Ammo belt feeding into receiver
  for (let i = 0; i < 5; i++) {
    const shell = new THREE.CylinderGeometry(0.0045, 0.0045, 0.05, 8);
    shell.rotateZ(Math.PI / 2);
    b.add('BeltRound', shell, mats.brass, -0.03 + i * 0.004, 0.03 - i * 0.012, 0.05 + i * 0.011);
  }
  // Deployed bipod
  b.box('BipodMount', 0.03, 0.02, 0.03, mats.darkMetal, 0, 0.0, 0.8, 0.003);
  for (const s of [-1, 1]) {
    const leg = new THREE.CylinderGeometry(0.006, 0.006, 0.25, 8);
    leg.translate(0, -0.125, 0);
    b.add('BipodLeg', leg, mats.darkMetal, 0.015 * s, 0.0, 0.8, deg(-25), 0, deg(18 * s));
  }
  b.triggerGuard(0.035);
  b.marker('Muzzle', 0, 0.03, 1.0);
  b.marker('SupportHand', 0, -0.01, 0.36);
  b.root.userData = { type: 'machine_gun', damage: 28, fireRate: 13, magazine: 100 };
  return b.root;
}

export function createShotgun(mats) {
  const b = new GunBuilder('Shotgun', mats);
  b.grip(mats.wood, 25, 0.1);
  b.box('Receiver', 0.04, 0.065, 0.22, mats.gunMetal, 0, 0.02, 0.06, 0.008);
  b.tube('Barrel', 0.013, 0.5, mats.gunMetal, 0, 0.042, 0.17);
  b.tube('MagTube', 0.012, 0.42, mats.gunMetal, 0, 0.012, 0.17);
  b.tube('Pump', 0.02, 0.15, mats.wood, 0, 0.012, 0.26);
  for (let i = 0; i < 5; i++) {
    b.tube('PumpRidge', 0.0215, 0.008, mats.wood, 0, 0.012, 0.275 + i * 0.025);
  }
  b.add('Bead', new THREE.SphereGeometry(0.003, 8, 6), mats.brass, 0, 0.058, 0.66);
  b.box('Stock', 0.042, 0.06, 0.3, mats.wood, 0, -0.005, -0.2, 0.012, deg(6));
  b.box('StockButt', 0.044, 0.12, 0.1, mats.wood, 0, -0.03, -0.33, 0.015);
  b.box('ButtPad', 0.046, 0.125, 0.02, mats.strap, 0, -0.03, -0.39, 0.006);
  b.triggerGuard(0.035);
  b.marker('Muzzle', 0, 0.042, 0.67);
  b.marker('SupportHand', 0, -0.01, 0.33);
  b.root.userData = { type: 'shotgun', damage: 18, pellets: 8, fireRate: 1.2, magazine: 6 };
  return b.root;
}

export function createGrenade(mats) {
  const b = new GunBuilder('Grenade', mats);
  const body = new THREE.SphereGeometry(0.032, 24, 18);
  body.scale(1, 1.25, 1);
  b.add('Body', body, mats.pouch, 0, 0, 0);
  b.add('Fuse', new THREE.CylinderGeometry(0.012, 0.012, 0.025, 16), mats.gunMetal, 0, 0.045, 0);
  b.box('Spoon', 0.012, 0.07, 0.006, mats.gunMetal, 0.018, 0.02, 0, 0.002);
  b.add('PinRing', new THREE.TorusGeometry(0.012, 0.002, 6, 16), mats.buckle, -0.02, 0.055, 0, 0, Math.PI / 2);
  b.root.userData = { type: 'grenade', damage: 100, radius: 6 };
  return b.root;
}

export const WEAPON_BUILDERS = {
  Pistol: createPistol,
  AssaultRifle: createAssaultRifle,
  Shotgun: createShotgun,
  SniperRifle: createSniperRifle,
  MachineGun: createMachineGun,
  Grenade: createGrenade,
};
