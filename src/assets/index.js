import { createMaterials } from './materials.js';
import { createCharacter } from './character.js';
import { WEAPON_BUILDERS } from './weapons.js';
import { createMap } from './map.js';

// Every asset the game needs. Keys become GLB file names in exports/.
export const ASSETS = {
  soldier: { label: 'Soldier', category: 'Character', build: createCharacter },
  pistol: { label: 'Pistol', category: 'Weapon', build: WEAPON_BUILDERS.Pistol },
  assault_rifle: { label: 'Assault Rifle', category: 'Weapon', build: WEAPON_BUILDERS.AssaultRifle },
  shotgun: { label: 'Shotgun', category: 'Weapon', build: WEAPON_BUILDERS.Shotgun },
  sniper_rifle: { label: 'Sniper Rifle', category: 'Weapon', build: WEAPON_BUILDERS.SniperRifle },
  machine_gun: { label: 'Machine Gun', category: 'Weapon', build: WEAPON_BUILDERS.MachineGun },
  grenade: { label: 'Grenade', category: 'Weapon', build: WEAPON_BUILDERS.Grenade },
  training_island: { label: 'Training Island', category: 'Map', build: createMap },
};

export function buildAsset(key, mats = createMaterials()) {
  return ASSETS[key].build(mats);
}

export { createMaterials };
