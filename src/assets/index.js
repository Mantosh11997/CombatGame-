import { createMaterials } from './materials.js';
import { createCharacter } from './character.js';
import { WEAPON_BUILDERS, withLowDetail } from './weapons.js';
import { createMap } from './map.js';
import { createAirplane, createParachute, createMedkit, createAmmoBox } from './vehicles.js';
import { bakeAll, bakeByJoint, bakedMaterial } from './bake.js';

// Bot outfits: [shirt, pants, vest, skin, hair].
const OUTFITS = [
  [0xb59f72, 0x8c7a55, 0x5e5238, 0xc68863, 0x2a1d14],
  [0x50555c, 0x2f3338, 0x1f2226, 0x8d5a3b, 0x111111],
  [0x7a2a26, 0x3a3330, 0x2b2b2b, 0xe0b49a, 0x6b4a2a],
  [0x2e4a73, 0x2b3340, 0x1d2633, 0x6b4430, 0x0d0d0d],
];

// Low-detail soldier for AI players: fewer segments, one vertex-colored mesh
// per joint (~17 draw calls instead of ~70).
function createBotSoldier(variant) {
  const mats = createMaterials();
  const [shirt, pants, vest, skin, hair] = OUTFITS[variant];
  mats.shirt.color.setHex(shirt);
  mats.pants.color.setHex(pants);
  mats.vest.color.setHex(vest);
  mats.pouch.color.setHex(vest).offsetHSL(0, 0, 0.05);
  mats.skin.color.setHex(skin);
  mats.hair.color.setHex(hair);
  const soldier = createCharacter(mats, { lowDetail: true });
  return bakeByJoint(soldier, bakedMaterial('BotOutfit'));
}

// Single-mesh gun for bots and loot on the ground (markers are kept).
function lodGun(build) {
  const low = withLowDetail(build);
  return (mats) => bakeAll(low(mats), bakedMaterial('GunBaked', { roughness: 0.5, metalness: 0.35 }));
}

// Every asset the game needs. Keys become GLB file names in game/assets/models/.
export const ASSETS = {
  soldier: { label: 'Soldier', category: 'Character', build: createCharacter },
  ...Object.fromEntries(OUTFITS.map((_, i) => [
    `soldier_bot_${i}`, { label: `Bot Soldier ${i + 1}`, category: 'Character', build: () => createBotSoldier(i) },
  ])),
  pistol: { label: 'Pistol', category: 'Weapon', build: WEAPON_BUILDERS.Pistol },
  assault_rifle: { label: 'Assault Rifle', category: 'Weapon', build: WEAPON_BUILDERS.AssaultRifle },
  shotgun: { label: 'Shotgun', category: 'Weapon', build: WEAPON_BUILDERS.Shotgun },
  sniper_rifle: { label: 'Sniper Rifle', category: 'Weapon', build: WEAPON_BUILDERS.SniperRifle },
  machine_gun: { label: 'Machine Gun', category: 'Weapon', build: WEAPON_BUILDERS.MachineGun },
  grenade: { label: 'Grenade', category: 'Weapon', build: WEAPON_BUILDERS.Grenade },
  pistol_lod: { label: 'Pistol (low)', category: 'Weapon', build: lodGun(WEAPON_BUILDERS.Pistol) },
  assault_rifle_lod: { label: 'Assault Rifle (low)', category: 'Weapon', build: lodGun(WEAPON_BUILDERS.AssaultRifle) },
  shotgun_lod: { label: 'Shotgun (low)', category: 'Weapon', build: lodGun(WEAPON_BUILDERS.Shotgun) },
  sniper_rifle_lod: { label: 'Sniper Rifle (low)', category: 'Weapon', build: lodGun(WEAPON_BUILDERS.SniperRifle) },
  machine_gun_lod: { label: 'Machine Gun (low)', category: 'Weapon', build: lodGun(WEAPON_BUILDERS.MachineGun) },
  airplane: { label: 'Airplane', category: 'Vehicle', build: createAirplane },
  parachute: { label: 'Parachute', category: 'Vehicle', build: createParachute },
  medkit: { label: 'Medkit', category: 'Loot', build: createMedkit },
  ammo_box: { label: 'Ammo Box', category: 'Loot', build: createAmmoBox },
  training_island: { label: 'Training Island', category: 'Map', build: createMap },
};

export function buildAsset(key, mats = createMaterials()) {
  return ASSETS[key].build(mats);
}

export { createMaterials };
