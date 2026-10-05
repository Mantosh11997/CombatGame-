# CombatGame (Flutter)

A third-person 3D shooter built with Flutter and
[flutter_scene](https://pub.dev/packages/flutter_scene). You play a soldier on
Training Island, a map made in the repo's Three.js asset workshop, with five
guns and a firing range of practice targets.

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
| Move | Left joystick (push to the edge to sprint) | WASD (Shift to sprint) |
| Look | Drag on the right half of the screen | Drag on the right half |
| Fire | Big red button (drag on it to aim while firing) | F |
| Aim down sights | Aim button | Q or scroll wheel |
| Jump | Jump button | Space |
| Reload | Reload button | R |
| Switch gun | Tap a slot at the top | 1-5 |

## How it fits together

```
lib/main.dart               app shell, loading screen, SceneView + HUD
lib/game/game.dart          Game: loads the scene, camera, shooting, targets
lib/game/player.dart        movement, gravity, collision, animation blending
lib/game/collision_world.dart  terrain heightfield + box/circle colliders, raycasts
lib/game/weapons.dart       gun stats, ammo, reload, fire timing
lib/game/targets.dart       practice dummies (hit, fall, respawn)
lib/game/effects.dart       tracers, muzzle flash, impact puffs
lib/ui/hud.dart             joystick, buttons, crosshair, ammo and stats
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
- **Coordinates.** flutter_scene imports glTF with Z negated. The collision
  loader negates Z (and yaw) to match, and `test/collision_world_test.dart`
  checks this against spawn positions taken from the imported scene.

## Tests

```bash
flutter test      # collision and weapon logic
flutter analyze
```

## Not built yet

Enemies or bots, player health and damage, grenades, the shrinking safe
zone, loot pickups, vehicles, sound and multiplayer.
