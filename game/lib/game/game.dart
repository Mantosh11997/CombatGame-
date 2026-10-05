import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'battle_royale.dart';
import 'character_controller.dart';
import 'collision_world.dart';
import 'combatant.dart';
import 'effects.dart';
import 'targets.dart';
import 'weapons.dart';

enum GameMode { training, battleRoyale }

/// Controls the HUD and keyboard write into; the game reads them each tick.
class GameInput {
  /// Stick: x = right, y = forward, length up to 1.
  vm.Vector2 move = vm.Vector2.zero();
  bool sprint = false;
  bool fire = false;
  bool aim = false;

  /// Accumulated look drag in logical pixels since the last tick.
  double lookX = 0, lookY = 0;
  bool jump = false;
  bool reload = false;
  bool heal = false;
  bool pickup = false;
  int? selectWeapon;
}

/// Models loaded once per match and cloned for every soldier and item.
class GameAssets {
  late final Node soldier;
  late final List<Node> botSoldiers;
  late final Map<String, Node> guns;
  late final Map<String, Node> lowGuns;
  late final Node airplane;
  late final Node parachute;
  late final Node medkit;
  late final Node ammoBox;

  Future<void> load() async {
    soldier = await loadScene('assets/models/soldier.glb');
    botSoldiers = [for (var i = 0; i < 4; i++) await loadScene('assets/models/soldier_bot_$i.glb')];
    guns = {for (final s in weaponSpecs) s.id: await loadScene(s.asset)};
    lowGuns = {for (final s in weaponSpecs) s.id: await loadScene(s.lowAsset)};
    airplane = await loadScene('assets/models/airplane.glb');
    parachute = await loadScene('assets/models/parachute.glb');
    medkit = await loadScene('assets/models/medkit.glb');
    ammoBox = await loadScene('assets/models/ammo_box.glb');
  }
}

/// Owns the scene and everything shared by both modes: the island, the
/// player, the camera, shooting and effects. Battle royale specifics (plane,
/// bots, zone, loot) live in [BattleRoyale].
class Game {
  Game(this.mode);

  final GameMode mode;
  final Scene scene = Scene();
  final GameInput input = GameInput();

  /// Ticks once per frame so the HUD can rebuild.
  final ValueNotifier<int> frame = ValueNotifier(0);
  final math.Random random = math.Random();

  late final CollisionWorld world;
  late final Effects effects;
  final GameAssets assets = GameAssets();
  late final Combatant player;
  BattleRoyale? br;
  final List<TargetDummy> _targets = [];
  ui.Image? minimap;

  // Camera state.
  double cameraYaw = math.pi / 2;
  double cameraPitch = -0.12;
  double _cameraDistance = 3.4;
  vm.Vector3 eye = vm.Vector3.zero();
  vm.Vector3 lookTarget = vm.Vector3(0, 0, 1);
  double fov = 60 * vm.degrees2Radians;
  static const double lookSensitivity = 0.006;

  bool _triggerReleased = true;
  double _faceAimFor = 0;
  double hitMarker = 0;
  bool lastHitHead = false;
  int knockdowns = 0, hits = 0, shots = 0;

  bool get aiming => input.aim && player.onGround && player.armed;

  // Debug/automation flags from the URL (web) — ignored elsewhere:
  // ?speed=N runs N simulation steps per frame; ?autopilot=1 lets a bot
  // brain play for the player.
  static final Map<String, String> _debug = Uri.base.queryParameters;
  final int simSpeed = int.tryParse(_debug['speed'] ?? '') ?? 1;
  final bool autopilot = _debug['autopilot'] == '1';

  Future<void> load() async {
    await Scene.initializeStaticResources();

    final json = await rootBundle.loadString('assets/models/training_island.collision.json');
    world = CollisionWorld.fromJson(jsonDecode(json) as Map<String, dynamic>);

    final map = await loadScene('assets/models/training_island.glb');
    _markStatic(map);
    scene.add(map);
    _setUpLook();
    await assets.load();
    effects = Effects(scene);
    minimap = await _buildMinimap();

    final spawn = map.getChildByName('Spawn0')!.globalTransform.getTranslation();
    player = createCombatant(
      id: 0,
      name: 'You',
      isPlayer: true,
      model: assets.soldier,
      spawn: spawn,
      slotCount: mode == GameMode.training ? weaponSpecs.length : 2,
    );

    if (mode == GameMode.training) {
      for (final spec in weaponSpecs) {
        player.giveWeapon(spec);
      }
      player.selectSlot(0);
      player.controller.yaw = cameraYaw;
      _placeTargets(spawn);
    } else {
      br = BattleRoyale(this)..setUp();
      cameraYaw = br!.planeYaw;
      cameraPitch = -0.35;
    }
    _updateCamera(0);
  }

  /// A soldier with its own node, controller and parachute.
  Combatant createCombatant({
    required int id,
    required String name,
    required bool isPlayer,
    required Node model,
    required vm.Vector3 spawn,
    int slotCount = 2,
  }) {
    final node = Node(name: name);
    scene.add(node);
    // Parachute pack faces backwards: turn it to the soldier's back (+Z front).
    final chute = assets.parachute.clone()..rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), math.pi);
    final controller = CharacterController(
      node: node,
      world: world,
      model: isPlayer ? model : model.clone(),
      spawn: spawn,
      parachute: chute,
    );
    final socket = controller.model.getChildByName('RightHandSocket')!;
    return Combatant(
      id: id,
      name: name,
      isPlayer: isPlayer,
      controller: controller,
      socket: socket,
      gunModel: (spec) => (isPlayer ? assets.guns : assets.lowGuns)[spec.id]!.clone(),
      slotCount: slotCount,
    );
  }

  void _markStatic(Node node) {
    node.shadowStatic = true;
    for (final child in node.children) {
      _markStatic(child);
    }
  }

  void _setUpLook() {
    final sunDirection = vm.Vector3(-0.45, -1.0, 0.35)..normalize();
    scene.directionalLight = DirectionalLight(
      direction: sunDirection,
      color: vm.Vector3(1.0, 0.95, 0.86),
      intensity: 3.2,
      castsShadow: true,
      shadowMaxDistance: 70,
      shadowCascadeCount: 3,
    );
    final sky = GradientSkySource(
      zenithColor: vm.Vector3(0.12, 0.32, 0.7),
      horizonColor: vm.Vector3(0.62, 0.76, 0.9),
      groundColor: vm.Vector3(0.25, 0.27, 0.22),
      sunDirection: -sunDirection,
    );
    // EnvironmentSettings is the whole look, sky and image-based lighting
    // included: leaving `skybox`/`environment` out would clear them.
    scene.environmentSettings = EnvironmentSettings(
      skybox: Skybox(sky),
      environment: EnvironmentMap.fromSky(sky),
      toneMapping: ToneMappingMode.aces,
      exposure: 1.0,
      colorGradingEnabled: true,
      saturation: 1.1,
      contrast: 1.05,
      fogEnabled: true,
      fogMode: FogMode.exponential,
      fogColor: vm.Vector3(0.62, 0.74, 0.86),
      fogDensity: 0.006,
    );
  }

  void _placeTargets(vm.Vector3 spawn) {
    final factory = TargetDummy.factory();
    // A firing range down the road in front of the spawn, plus a few further
    // out in the field and near the warehouse for long shots.
    const offsets = <(double, double)>[
      (8, -2), (11, 2.5), (14, -1), (18, 3), (22, -2.5), (27, 1),
      (34, -3), (40, 2), (55, 14), (70, -12), (-15, 30), (25, -40),
    ];
    for (final (dx, dz) in offsets) {
      final x = spawn.x + dx, z = spawn.z + dz;
      if (world.boxes.any((b) => b.containsXZ(x, z, 0.6))) continue;
      final base = vm.Vector3(x, world.groundHeight(x, z, world.terrainHeight(x, z)), z);
      final yaw = math.atan2(spawn.x - x, spawn.z - z);
      final dummy = factory.create(base, yaw);
      scene.add(dummy.root);
      _targets.add(dummy);
    }
  }

  /// Top-down picture of the island for the minimap: up is +Z.
  Future<ui.Image> _buildMinimap() async {
    const px = 256.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final segments = world.segments;
    final cell = px / segments;
    final paint = Paint();
    for (var iz = 0; iz <= segments; iz++) {
      for (var ix = 0; ix <= segments; ix++) {
        final h = world.heights[iz * (segments + 1) + ix];
        paint.color = h < world.seaLevel
            ? const Color(0xFF2B5D75)
            : h < 1.2
            ? const Color(0xFFCBB98A)
            : Color.lerp(const Color(0xFF5D7A3A), const Color(0xFF8E9A6A), (h / 18).clamp(0, 1))!;
        // Heightfield row iz is glTF z, i.e. engine z = size/2 - iz * cell.
        canvas.drawRect(Rect.fromLTWH(ix * cell - cell / 2, iz * cell - cell / 2, cell + 0.6, cell + 0.6), paint);
      }
    }
    paint.color = const Color(0xFF55585C);
    for (final b in world.boxes) {
      if (b.top - world.terrainHeight(b.center.x, b.center.z) < 2) continue;
      canvas.drawRect(
        Rect.fromLTRB(mapX(b.minX) * px, mapY(b.maxZ) * px, mapX(b.maxX) * px, mapY(b.minZ) * px),
        paint,
      );
    }
    return recorder.endRecording().toImage(px.toInt(), px.toInt());
  }

  /// World -> minimap coordinates (0..1), up is +Z.
  double mapX(double x) => (x + world.size / 2) / world.size;
  double mapY(double z) => (world.size / 2 - z) / world.size;

  // ------------------------------------------------------------------ tick

  void tick(double dt) {
    if (dt <= 0) return;
    for (var i = 0; i < simSpeed; i++) {
      _step(math.min(dt, 1 / 20));
    }
    frame.value++;
  }

  void _step(double dt) {
    _playerInput(dt);
    br?.tick(dt);
    if (br == null) {
      player.controller.update(dt);
      player.update(dt);
      for (final t in _targets) {
        t.update(dt);
      }
    }
    _updateCamera(dt);
    player.aimPitch = _faceAimFor > 0 ? cameraPitch : 0;
    player.alignGun();
    _playerShooting();
    effects.update(dt);
    if (hitMarker > 0) hitMarker -= dt;
  }

  void _playerInput(double dt) {
    final c = player.controller;
    final zoom = aiming ? player.weapon!.spec.zoom : 1.0;
    cameraYaw += input.lookX * lookSensitivity / zoom;
    cameraPitch = (cameraPitch - input.lookY * lookSensitivity / zoom).clamp(-1.2, 0.9);
    input.lookX = input.lookY = 0;

    final select = input.selectWeapon;
    input.selectWeapon = null;
    if (select != null) player.selectSlot(select);
    if (input.reload) player.weapon?.startReload();
    input.reload = false;
    if (input.heal) player.startHeal();
    input.heal = false;
    if (input.pickup) br?.playerSwap();
    input.pickup = false;

    if (input.jump) {
      switch (c.mode) {
        case MoveMode.plane:
          br?.playerJump();
        case MoveMode.freefall:
          if (c.canOpenParachute) c.openParachute();
        case MoveMode.ground:
          c.jump();
        case _:
          break;
      }
    }
    input.jump = false;

    if (autopilot) return; // a BotBrain drives the player's controller

    c
      ..moveInput = player.alive ? input.move : vm.Vector2.zero()
      ..sprint = input.sprint || input.move.length > 0.92
      ..cameraYaw = cameraYaw;

    // Face the crosshair while aiming or shortly after shooting.
    if ((input.fire || input.aim) && player.armed) _faceAimFor = 0.8;
    _faceAimFor -= dt;
    c.faceYaw = _faceAimFor > 0 && player.onGround ? cameraYaw : null;
    if (_faceAimFor > 0) c.sprint = false;
  }

  void _playerShooting() {
    final weapon = player.weapon;
    if (!input.fire) {
      _triggerReleased = true;
      weapon?.settle();
    }
    if (weapon == null || !player.alive || !player.onGround || !input.fire || autopilot) return;
    if (!(weapon.spec.automatic || _triggerReleased)) return;
    _triggerReleased = false;
    if (player.healing) player.cancelHeal();
    final dir = aimDirection;
    // Start the aim ray level with the player so nothing behind them counts.
    final origin = eye + dir * _cameraDistance;
    var fired = 0;
    // A long frame can owe an automatic gun more than one shot.
    while (fired < 3 && fireWeapon(player, origin, dir)) {
      fired++;
      cameraPitch = (cameraPitch + weapon.spec.recoil).clamp(-1.2, 0.9);
      cameraYaw += (random.nextDouble() - 0.5) * weapon.spec.recoil * 0.5;
      if (!weapon.spec.automatic) break;
    }
  }

  vm.Vector3 get aimDirection => vm.Vector3(
    math.cos(cameraPitch) * math.sin(cameraYaw),
    math.sin(cameraPitch),
    math.cos(cameraPitch) * math.cos(cameraYaw),
  );

  // ------------------------------------------------------------------ camera

  void _updateCamera(double dt) {
    final c = player.controller;
    final dir = aimDirection;
    final right = CharacterController.headingRight(cameraYaw);
    vm.Vector3 pivot;
    double wanted;
    var collide = true;

    switch (c.mode) {
      case MoveMode.plane:
        pivot = br!.planePosition;
        wanted = 34;
        collide = false;
      case MoveMode.freefall:
      case MoveMode.parachute:
        pivot = c.position + vm.Vector3(0, c.mode == MoveMode.parachute ? 2.5 : 1.0, 0);
        wanted = c.mode == MoveMode.parachute ? 8.5 : 6.5;
        collide = false;
      case MoveMode.dead:
        // Spectate whoever is still alive: the killer if possible.
        final watch = br?.spectateTarget(player) ?? player;
        pivot = watch.position + vm.Vector3(0, 1.6, 0);
        wanted = 5;
        cameraYaw += dt * 0.15;
      case MoveMode.ground:
        pivot = c.position + vm.Vector3(0, aiming ? 1.6 : 1.55, 0) + right * (aiming ? 0.45 : 0.55);
        wanted = aiming ? 1.5 : 3.4;
    }

    if (collide) {
      // Pull the camera in front of walls between it and the player.
      final hit = world.raycast(pivot, -dir, wanted + 0.3);
      // Spectating keeps more room so the camera never sits inside a head.
      final closest = c.mode == MoveMode.dead ? 1.4 : 0.4;
      if (hit != null) wanted = math.max(closest, hit.distance - 0.3);
    }
    // Snap in immediately, ease back out.
    _cameraDistance = wanted < _cameraDistance || dt == 0
        ? wanted
        : _cameraDistance + (wanted - _cameraDistance) * (1 - math.exp(-6 * dt));

    eye = pivot - dir * _cameraDistance;
    final floor = world.terrainHeight(eye.x, eye.z) + 0.3;
    if (eye.y < floor) eye.y = floor;
    lookTarget = eye + dir * 10;

    // Thin the haze with altitude so the island stays readable from the plane.
    final altitude = math.max(0.0, eye.y - 10);
    scene.fog.density = 0.006 / (1 + altitude / 25);

    final targetFov = 60 * vm.degrees2Radians / (aiming ? player.weapon!.spec.zoom : 1);
    fov += (targetFov - fov) * (dt == 0 ? 1 : 1 - math.exp(-14 * dt));
  }

  Camera camera() => PerspectiveCamera(
    position: eye,
    target: lookTarget,
    fovRadiansY: fov,
    fovNear: 0.05,
    fovFar: 700,
  );

  // ------------------------------------------------------------------ shooting

  /// Fires [shooter]'s current gun once along [dir] from [origin] (the
  /// player's crosshair ray, or a bot's eye). Applies the same spread, range
  /// and damage for everyone. Returns false when the gun could not fire.
  bool fireWeapon(Combatant shooter, vm.Vector3 origin, vm.Vector3 dir) {
    final weapon = shooter.weapon;
    if (weapon == null || !shooter.alive) return false;
    if (!weapon.tryFire()) {
      if (weapon.ammo == 0) weapon.startReload();
      return false;
    }
    if (shooter.isPlayer) shots++;
    br?.onShot(shooter);
    final spec = weapon.spec;
    final muzzle = shooter.muzzle;
    final visible = muzzle.distanceTo(eye) < 120;
    if (visible) effects.muzzleFlash(muzzle);
    final aimedDown = shooter.isPlayer && aiming;

    for (var p = 0; p < spec.pellets; p++) {
      final shotDir = _spread(dir, aimedDown ? spec.spread * 0.4 : spec.spread);
      var end = origin + shotDir * spec.range;
      var bestT = spec.range;
      Combatant? victim;
      TargetDummy? dummy;
      var head = false;
      final wall = world.raycast(origin, shotDir, spec.range);
      if (wall != null) {
        bestT = wall.distance;
        end = wall.point;
      }
      for (final t in _targets) {
        final hit = t.raycast(origin, shotDir, bestT);
        if (hit != null && hit.$1 < bestT) {
          (bestT, head) = hit;
          end = origin + shotDir * bestT;
          dummy = t;
          victim = null;
        }
      }
      for (final other in br?.combatants ?? const <Combatant>[]) {
        if (identical(other, shooter)) continue;
        final hit = other.raycast(origin, shotDir, bestT);
        if (hit != null && hit.$1 < bestT) {
          (bestT, head) = hit;
          end = origin + shotDir * bestT;
          victim = other;
          dummy = null;
        }
      }
      if (shooter.isPlayer) {
        // The bullet leaves the muzzle; stop it at anything right in front.
        final fromMuzzle = end - muzzle;
        final length = fromMuzzle.length;
        if (length > 0.2) {
          final blocked = world.raycast(muzzle, fromMuzzle / length, length - 0.1);
          if (blocked != null) {
            end = blocked.point;
            victim = null;
            dummy = null;
          }
        }
      }
      if (visible || victim?.isPlayer == true) effects.tracer(muzzle, end);
      final damage = spec.damage * (head ? 2 : 1);
      if (dummy != null) {
        if (dummy.damage(damage)) knockdowns++;
      } else if (victim != null) {
        if (victim.takeDamage(damage, shooter)) br?.onEliminated(victim, shooter, spec.name, head);
      }
      if (dummy != null || victim != null) {
        if (shooter.isPlayer) {
          hits++;
          hitMarker = 0.18;
          lastHitHead = head;
        }
        if (end.distanceTo(eye) < 120) effects.impact(end, flesh: true);
      } else if (bestT < spec.range && end.distanceTo(eye) < 120) {
        effects.impact(end);
      }
    }
    return true;
  }

  vm.Vector3 _spread(vm.Vector3 dir, double cone) {
    if (cone <= 0) return dir;
    final up = vm.Vector3(0, 1, 0);
    final right = dir.cross(up)..normalize();
    final realUp = right.cross(dir)..normalize();
    final a = random.nextDouble() * math.pi * 2;
    final r = math.sqrt(random.nextDouble()) * cone;
    return (dir + right * (math.cos(a) * r) + realUp * (math.sin(a) * r))..normalize();
  }
}
