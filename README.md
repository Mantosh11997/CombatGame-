# CombatGame

A battle-royale style 3D shooter in two parts:

- **[`game/`](game/)**: the playable Flutter game, built with flutter_scene.
  See [game/README.md](game/README.md) for how to run it and the controls.
- **This folder**: a Three.js workshop that builds the game's 3D assets and
  exports them as `.glb` (binary glTF) files into `game/assets/models/`.

All assets are generated in code: no image textures and no external model
files. Every build produces the same output.

## Assets

| File | What it is |
| --- | --- |
| `soldier.glb` | ~1.80 m soldier with tactical vest, pouches, belt and holster, knee pads, boots and gloves. Rigged as a joint hierarchy with Mixamo-style names (`Hips`, `Spine`, `Chest`, `Neck`, `Head`, `LeftArm`, `RightForeArm`, `LeftUpLeg`...). Includes 6 animations: `Idle`, `Walk`, `Run`, `Aim`, plus `WalkAim` and `RunAim` (legs moving, gun held up). |
| `pistol.glb` | Semi-auto pistol |
| `assault_rifle.glb` | M4-style rifle with red dot, rail, curved magazine and fore grip |
| `shotgun.glb` | Pump-action shotgun with wooden furniture |
| `sniper_rifle.glb` | Bolt-action rifle with scope and bipod |
| `machine_gun.glb` | Belt-fed light machine gun with ammo box, carry handle and deployed bipod |
| `grenade.glb` | Frag grenade |
| `training_island.glb` | 240 m × 240 m island map: terrain, sea, road, a town of 6 enterable houses (some two-storey with stairs), a warehouse, a watchtower on a hill, ~220 trees, rocks, crates, sandbag walls, an airdrop crate and 8 spawn points |

Prebuilt files are in [`game/assets/models/`](game/assets/models/). The map
also gets `training_island.collision.json`, the gameplay collision data the
game uses (terrain heightfield, wall/floor boxes, tree and rock circles).

### Conventions (for the game code)

- Units are meters. +Y is up and characters face +Z (the glTF standard).
- **Character:** the empty node `RightHandSocket` is where a gun attaches.
- **Guns:** the origin is the top of the pistol grip and the barrel points
  along +Z. The empty node `Muzzle` is where bullets and muzzle flash spawn,
  and `SupportHand` is where the left hand goes. Stats such as damage, fire
  rate and magazine size are in each gun's glTF `extras`.
- **Map:** buildings are nodes named `House_A`...`House_F`, `Warehouse` and
  `Watchtower`. Cover objects are `Crate*` and `Sandbags*`. Spawn points are
  the empty nodes `Spawn0`...`Spawn7` under `SpawnPoints`. Each node's
  `extras.type` (`building`, `cover`, `tower`, `airdrop`) is there to help
  set up collision.

## Usage

```bash
npm install
npm run dev        # open the viewer at http://localhost:5173
npm run export     # rebuild every .glb into game/assets/models/
npm run export -- soldier machine_gun   # rebuild only some assets
```

In the viewer you can:

- orbit around any asset
- play the soldier's animations
- equip any weapon on the soldier
- download the selected asset as `.glb`

URL parameters open a view directly, for example
`/?asset=soldier&equip=machine_gun&anim=Aim`.

## Project layout

```
src/assets/materials.js   shared PBR materials
src/assets/character.js   soldier model + animation clips
src/assets/weapons.js     all weapons (GunBuilder helper)
src/assets/map.js         island map, getHeight(x, z) for ground height
src/assets/index.js       asset registry (keys = export file names)
src/viewer/               browser viewer
scripts/export-glb.mjs    Node exporter -> game/assets/models/*.glb
```

## Using the assets in Flutter

The game in [`game/`](game/) loads these files with flutter_scene. Its build
hook converts each `.glb` at build time, so after `npm run export` just
rebuild the game. The files are standard glTF 2.0 and pass the Khronos glTF
validator with no errors.
