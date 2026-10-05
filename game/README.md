# CombatGame (Flutter)

A third-person 3D battle royale built with Flutter and
[flutter_scene](https://pub.dev/packages/flutter_scene).

**Start** puts you on a plane with 49 AI players over Training Island. Jump
when you like, skydive, open your parachute, land, find guns, medkits and
ammo, and survive while the safe zone shrinks. The last one standing wins
("BOOYAH!"). The AI players follow the same rules as you: they ride the same
plane, choose where to drop, loot, heal, fight each other and you, and run
from the zone.

**Training** is a firing range with every gun and practice targets.

## Run it

Needs Flutter 3.47 or newer (stable).

```bash
cd game
flutter pub get
flutter run --enable-flutter-gpu   # Android / iOS / desktop
flutter run -d chrome              # web
```

Flutter GPU is already switched on for Android (`AndroidManifest.xml`) and
iOS (`Info.plist`), so release builds need no flag. The web needs nothing.

## Controls

| Action | Touch | Keyboard / mouse |
| --- | --- | --- |
| Jump from the plane / open parachute | Big button in the middle | Space |
| Move | Left joystick (push to the edge to sprint) | WASD (Shift to sprint) |
| Look | Drag on the right half of the screen | Drag on the right half |
| Fire | Big red button (drag on it to aim while firing) | F |
| Aim down sights | Aim button | Q or scroll wheel |
| Jump | Jump button | Space |
| Reload | Reload button | R |
| Use medkit | Medkit button (shows how many you carry) | H |
| Swap for the gun on the ground | "Swap for ..." button | E |
| Switch gun | Tap a slot at the top | 1-5 |

Walking over a gun picks it up when you have a free slot (two slots in a
match); medkits (up to 5) and ammo are picked up automatically.

## The match

- **Plane:** flies straight across the island on a random line. The minimap
  shows its path. Everyone still aboard is dropped at the end of the line.
- **Drop:** freefall at ~28 m/s, steering with the stick. The parachute can
  be opened below 95 m and opens by itself at 38 m.
- **Loot:** ~110 items spawn on house floors, in the warehouse and on open
  ground. Eliminated players drop everything they carried.
- **Safe zone:** appears when the plane has passed. Five phases: wait, then
  shrink (to 85 m, 50 m, 26 m, 10 m and 0 m radius). Outside the circle you
  lose 2 to 15 health per second, depending on the phase.
- **Damage:** the same for everyone. Headshots do double damage. Health is
  100. A medkit heals 75 over 2.5 s.
- **AI:** each bot has a skill level (reaction time, turn speed, accuracy).
  Bots only see enemies in front of them within range and with a clear line
  of sight. They hear gunfire within 90 m, and they never shoot at players
  still in the air.

## How it fits together

```
lib/main.dart                      menu, loading, SceneView + HUD
lib/game/game.dart                 Game: scene, assets, camera, player input, shooting
lib/game/battle_royale.dart        the match: plane, bots, zone, loot, eliminations
lib/game/bot_brain.dart            AI decisions (drop, loot, fight, heal, zone)
lib/game/combatant.dart            a soldier: health, guns, medkits, hit box
lib/game/character_controller.dart movement for everyone: plane, freefall,
                                   parachute, walking, death; animation blending
lib/game/zone.dart                 shrinking safe zone (pure logic)
lib/game/loot.dart                 loot table and placement
lib/game/collision_world.dart      terrain heightfield + colliders, raycasts
lib/game/weapons.dart              gun stats, ammo, reload, fire timing
lib/game/targets.dart              training dummies
lib/game/effects.dart              tracers, muzzle flash, impacts
lib/ui/hud.dart, lib/ui/minimap.dart  controls, readouts, minimap, results
```

- **Assets.** The `.glb` files in `assets/models/` come from the Three.js
  workshop at the repo root (`npm run export` regenerates them). flutter_scene's
  build hook (`hook/build.dart`) converts each one at build time into its
  fast-loading format, and the game loads them with `loadScene(...)`.
- **Collision.** The exporter also writes
  `training_island.collision.json`: the terrain heightfield plus boxes for
  every wall, floor, stair and crate, and circles for trees and rocks. The
  game moves the player and casts bullets against that data instead of
  against rendered triangles, which keeps it cheap on phones. Box tops count
  as floors, so stairs and upper storeys are walkable.
- **50 soldiers on a phone.** Bots use a low-detail soldier (6.7k
  triangles, one vertex-coloured mesh per joint, about 17 draw calls) in 4
  outfits, and single-mesh guns. Soldiers further than 160 m and loot
  further than 45 m are hidden. The player keeps the full-detail model.
- **Coordinates.** flutter_scene imports glTF with Z negated. The collision
  loader negates Z (and yaw) to match, and `test/collision_world_test.dart`
  checks this against spawn positions taken from the imported scene.

## Tests

```bash
flutter test      # collision, weapons, safe zone, loot placement
flutter analyze
```

On the web, two URL flags help test a whole match quickly:
`?mode=br&speed=30&autopilot=1` skips the menu, runs 30 simulation steps per
frame, and lets an AI play for you. The match log (drops, every elimination,
the winner) is printed to the browser console.

## Not built yet

Grenades (the model exists), armour and helmets, vehicles, sound, squads and
online multiplayer.
