import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'collision_world.dart';
import 'effects.dart';
import 'player.dart';
import 'targets.dart';
import 'weapons.dart';

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
  int? selectWeapon;
}

typedef HudState = ({
  int weapon,
  int ammo,
  int reserve,
  double reload,
  int knockdowns,
  int hits,
  int shots,
  bool hitMarker,
  bool headshot,
  bool aiming,
});

/// Owns the scene and all game state: the island, the player, the guns,
/// the camera, shooting and the practice targets.
class Game {
  final Scene scene = Scene();
  final GameInput input = GameInput();
  final ValueNotifier<HudState?> hud = ValueNotifier(null);

  late final CollisionWorld world;
  late final PlayerController player;
  late final Effects _effects;
  final List<TargetDummy> _targets = [];

  late final Node _playerNode;
  late final Node _modelHolder;
  late final Node _socket;
  final List<Node> _gunHolders = [];
  final List<Node?> _muzzles = [];
  final List<WeaponState> weapons = [for (final spec in weaponSpecs) WeaponState(spec)];
  int _current = 0;

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
  double _hitMarker = 0;
  bool _lastHitHead = false;
  int _knockdowns = 0, _hits = 0, _shots = 0;
  final _random = math.Random();

  WeaponState get weapon => weapons[_current];

  Future<void> load() async {
    await Scene.initializeStaticResources();

    final json = await rootBundle.loadString('assets/models/training_island.collision.json');
    world = CollisionWorld.fromJson(jsonDecode(json) as Map<String, dynamic>);

    final map = await loadScene('assets/models/training_island.glb');
    _markStatic(map);
    scene.add(map);
    _setUpLook();

    final soldier = await loadScene('assets/models/soldier.glb');
    // The soldier faces -Z after import; turn it so the player's +Z is forward.
    _modelHolder = Node()..rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), math.pi);
    _modelHolder.add(soldier);
    _playerNode = Node(name: 'Player')..add(_modelHolder);
    scene.add(_playerNode);
    final spawn = map.getChildByName('Spawn0')!.globalTransform.getTranslation();
    player = PlayerController(_playerNode, world, soldier, spawn)..yaw = cameraYaw;

    _socket = soldier.getChildByName('RightHandSocket')!;
    for (final spec in weaponSpecs) {
      final gun = await loadScene(spec.asset);
      final holder = Node()..visible = false;
      holder.add(gun);
      _socket.add(holder);
      _gunHolders.add(holder);
      _muzzles.add(gun.getChildByName('Muzzle'));
    }
    _equip(0);

    _effects = Effects(scene);
    _placeTargets(spawn);
    _updateCamera(0);
    _publishHud();
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
      // Face the spawn point.
      final yaw = math.atan2(spawn.x - x, spawn.z - z);
      final dummy = factory.create(base, yaw);
      scene.add(dummy.root);
      _targets.add(dummy);
    }
  }

  void _equip(int index) {
    weapon.cancelReload();
    _current = index;
    for (var i = 0; i < _gunHolders.length; i++) {
      _gunHolders[i].visible = i == index;
    }
    player.armed = true;
    _triggerReleased = false;
  }

  // ------------------------------------------------------------------ tick

  void tick(double dt) {
    if (dt <= 0) return;
    dt = math.min(dt, 1 / 20);

    // Weapon selection and reload.
    final select = input.selectWeapon;
    input.selectWeapon = null;
    if (select != null && select != _current && select < weapons.length) _equip(select);
    if (input.reload) weapon.startReload();
    input.reload = false;
    for (final w in weapons) {
      w.update(w == weapon ? dt : 0);
    }

    // Look.
    cameraYaw += input.lookX * lookSensitivity / (input.aim ? weapon.spec.zoom : 1);
    cameraPitch = (cameraPitch - input.lookY * lookSensitivity / (input.aim ? weapon.spec.zoom : 1)).clamp(-1.2, 0.9);
    input.lookX = input.lookY = 0;

    // Move.
    player
      ..moveInput = input.move
      ..sprint = input.sprint || input.move.length > 0.92
      ..cameraYaw = cameraYaw;
    if (input.jump) player.jump();
    input.jump = false;

    // Face the crosshair while aiming or shortly after shooting.
    if (input.fire || input.aim) _faceAimFor = 0.8;
    _faceAimFor -= dt;
    player.faceYaw = _faceAimFor > 0 ? cameraYaw : null;
    if (_faceAimFor > 0) player.sprint = false;
    player.update(dt);

    _updateCamera(dt);
    _alignGun();

    // Shooting: automatic guns fire while held, others once per press.
    if (!input.fire) {
      _triggerReleased = true;
      weapon.settle();
    }
    if (input.fire && (weapon.spec.automatic || _triggerReleased)) {
      // A long frame can owe an automatic gun more than one shot.
      var shots = 0;
      while (shots < 3 && weapon.tryFire()) {
        _fire();
        shots++;
        if (!weapon.spec.automatic) break;
      }
      if (shots == 0 && weapon.ammo == 0) weapon.startReload();
      _triggerReleased = false;
    }

    for (final t in _targets) {
      t.update(dt);
    }
    _effects.update(dt);
    if (_hitMarker > 0) _hitMarker -= dt;
    _publishHud();
  }

  vm.Vector3 get _aimDirection => vm.Vector3(
    math.cos(cameraPitch) * math.sin(cameraYaw),
    math.sin(cameraPitch),
    math.cos(cameraPitch) * math.cos(cameraYaw),
  );

  void _updateCamera(double dt) {
    final aiming = input.aim;
    final dir = _aimDirection;
    final right = PlayerController.headingRight(cameraYaw);
    final pivot = player.position + vm.Vector3(0, aiming ? 1.6 : 1.55, 0) + right * (aiming ? 0.45 : 0.55);

    // Pull the camera in front of walls between it and the player.
    var wanted = aiming ? 1.5 : 3.4;
    final hit = world.raycast(pivot, -dir, wanted + 0.3);
    if (hit != null) wanted = math.max(0.4, hit.distance - 0.3);
    // Snap in immediately, ease back out.
    _cameraDistance = wanted < _cameraDistance
        ? wanted
        : _cameraDistance + (wanted - _cameraDistance) * (1 - math.exp(-6 * dt));

    eye = pivot - dir * _cameraDistance;
    final floor = world.terrainHeight(eye.x, eye.z) + 0.3;
    if (eye.y < floor) eye.y = floor;
    lookTarget = eye + dir * 10;

    final targetFov = 60 * vm.degrees2Radians / (aiming ? weapon.spec.zoom : 1);
    fov += (targetFov - fov) * (1 - math.exp(-14 * dt));
  }

  Camera camera() => PerspectiveCamera(
    position: eye,
    target: lookTarget,
    fovRadiansY: fov,
    fovNear: 0.05,
    fovFar: 600,
  );

  /// Keeps the gun pointing along the player's facing (tilted with the camera
  /// pitch), whatever the animated hand is doing.
  void _alignGun() {
    final socketRotation = _socket.globalTransform.getRotation()..transpose();
    final desired = vm.Matrix3.rotationY(player.yaw + math.pi) * vm.Matrix3.rotationX(cameraPitch);
    _gunHolders[_current].rotation = vm.Quaternion.fromRotation(socketRotation * desired);
  }

  void _fire() {
    _shots++;
    final spec = weapon.spec;
    final dir = _aimDirection;
    // Start the aim ray level with the player so nothing behind them counts.
    final origin = eye + dir * _cameraDistance;
    final muzzleNode = _muzzles[_current];
    final muzzle = muzzleNode?.globalTransform.getTranslation() ?? (player.position + vm.Vector3(0, 1.4, 0));
    _effects.muzzleFlash(muzzle);

    for (var p = 0; p < spec.pellets; p++) {
      final shotDir = _spread(dir, spec.spread);
      var end = origin + shotDir * spec.range;
      var bestT = spec.range;
      TargetDummy? hitTarget;
      var head = false;
      final wall = world.raycast(origin, shotDir, spec.range);
      if (wall != null) {
        bestT = wall.distance;
        end = wall.point;
      }
      for (final t in _targets) {
        final hit = t.raycast(origin, shotDir, bestT);
        if (hit != null && hit.$1 < bestT) {
          bestT = hit.$1;
          end = origin + shotDir * bestT;
          hitTarget = t;
          head = hit.$2;
        }
      }
      // The bullet leaves the muzzle; stop it at anything right in front.
      final fromMuzzle = end - muzzle;
      final length = fromMuzzle.length;
      if (length > 0.2) {
        final blocked = world.raycast(muzzle, fromMuzzle / length, length - 0.1);
        if (blocked != null) {
          end = blocked.point;
          hitTarget = null;
        }
      }
      _effects.tracer(muzzle, end);
      if (hitTarget != null) {
        _hits++;
        _hitMarker = 0.18;
        _lastHitHead = head;
        if (hitTarget.damage(spec.damage * (head ? 2 : 1))) _knockdowns++;
        _effects.impact(end, flesh: true);
      } else if (bestT < spec.range) {
        _effects.impact(end);
      }
    }

    // Recoil kick.
    cameraPitch = (cameraPitch + spec.recoil).clamp(-1.2, 0.9);
    cameraYaw += (_random.nextDouble() - 0.5) * spec.recoil * 0.5;
  }

  vm.Vector3 _spread(vm.Vector3 dir, double cone) {
    if (cone <= 0) return dir;
    final aimCone = input.aim ? cone * 0.4 : cone;
    final up = vm.Vector3(0, 1, 0);
    final right = dir.cross(up)..normalize();
    final realUp = right.cross(dir)..normalize();
    final a = _random.nextDouble() * math.pi * 2;
    final r = math.sqrt(_random.nextDouble()) * aimCone;
    return (dir + right * (math.cos(a) * r) + realUp * (math.sin(a) * r))..normalize();
  }

  void _publishHud() {
    hud.value = (
      weapon: _current,
      ammo: weapon.ammo,
      reserve: weapon.reserve,
      reload: weapon.reloading ? 1 - weapon.reloadLeft / weapon.spec.reloadTime : 0,
      knockdowns: _knockdowns,
      hits: _hits,
      shots: _shots,
      hitMarker: _hitMarker > 0,
      headshot: _lastHitHead,
      aiming: input.aim,
    );
  }
}
