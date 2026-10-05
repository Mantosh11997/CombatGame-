import * as THREE from 'three';

// Shared PBR materials. Plain colors only (no image textures) so every asset
// can be built and exported to GLB in Node as well as in the browser.
function pbr(name, color, roughness, metalness = 0, extra = {}) {
  return new THREE.MeshStandardMaterial({ name, color, roughness, metalness, ...extra });
}

export function createMaterials() {
  return {
    // Character
    skin: pbr('Skin', 0xc68863, 0.55),
    lips: pbr('Lips', 0xa05a4a, 0.5),
    eyeWhite: pbr('EyeWhite', 0xf2efe8, 0.2),
    iris: pbr('Iris', 0x3b2a1a, 0.15),
    hair: pbr('Hair', 0x1c1410, 0.85),
    shirt: pbr('Shirt', 0x4a5236, 0.9),
    pants: pbr('Pants', 0x3d4230, 0.9),
    vest: pbr('Vest', 0x2b2f24, 0.75),
    pouch: pbr('Pouch', 0x353a2b, 0.8),
    strap: pbr('Strap', 0x1e201a, 0.7),
    glove: pbr('Glove', 0x1a1a1a, 0.6),
    boot: pbr('Boot', 0x2a2018, 0.5),
    sole: pbr('Sole', 0x111111, 0.9),
    buckle: pbr('Buckle', 0x777770, 0.35, 0.8),

    // Weapons
    gunMetal: pbr('GunMetal', 0x3a3d41, 0.4, 0.6),
    darkMetal: pbr('DarkMetal', 0x26282b, 0.45, 0.6),
    polymer: pbr('Polymer', 0x1f2022, 0.65),
    wood: pbr('Wood', 0x6b4226, 0.6),
    tan: pbr('TanPolymer', 0x9c8a66, 0.7),
    brass: pbr('Brass', 0xb08d3c, 0.3, 1),
    lens: pbr('Lens', 0x1a3a4a, 0.05, 0.3, { emissive: 0x05121a }),
    redDot: pbr('RedDot', 0xff2020, 0.3, 0, { emissive: 0xff0000, emissiveIntensity: 2 }),

    // Map
    concrete: pbr('Concrete', 0x9a978f, 0.95),
    wallPlaster: pbr('Plaster', 0xc9bfa8, 0.9),
    roofTile: pbr('Roof', 0x7a3b2a, 0.8),
    windowGlass: pbr('Glass', 0x5a7d8c, 0.1, 0.5),
    door: pbr('Door', 0x4b3020, 0.7),
    asphalt: pbr('Asphalt', 0x2f3032, 0.95),
    roadLine: pbr('RoadLine', 0xd8d2b0, 0.8),
    bark: pbr('Bark', 0x4a3524, 0.95),
    leaves: pbr('Leaves', 0x3f6b2e, 0.9),
    pineLeaves: pbr('PineLeaves', 0x2a4a2a, 0.9),
    rock: pbr('Rock', 0x7c786f, 0.95),
    crateWood: pbr('CrateWood', 0x8a6a3e, 0.85),
    metalSheet: pbr('MetalSheet', 0x5d6660, 0.5, 0.7),
    sandbag: pbr('Sandbag', 0xa89670, 0.95),
    water: pbr('Water', 0x2b5d75, 0.1, 0.1, { transparent: true, opacity: 0.85 }),
    terrain: pbr('Terrain', 0xffffff, 0.95, 0, { vertexColors: true }),
    airdrop: pbr('Airdrop', 0x2266cc, 0.6),
    airdropStripe: pbr('AirdropStripe', 0xffcc00, 0.6),
  };
}
