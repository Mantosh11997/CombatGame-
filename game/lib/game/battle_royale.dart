import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'bot_brain.dart';
import 'character_controller.dart';
import 'collision_world.dart';
import 'combatant.dart';
import 'game.dart';
import 'loot.dart';
import 'weapons.dart';
import 'zone.dart';

enum MatchPhase { plane, battle, ended }

class KillFeedEntry {
  KillFeedEntry(this.killer, this.victim, this.weapon, this.headshot, this.time);
  final String? killer;
  final String victim;
  final String weapon;
  final bool headshot;
  final double time;
}

/// A 50-player battle royale: everyone rides the plane over the island,
/// jumps, lands, loots and fights while the safe zone closes in. The last
/// soldier standing wins.
class BattleRoyale implements BattleContext {
  BattleRoyale(this.game);

  static const int playerCount = 50;
  static const double planeAltitude = 105;
  static const double planeSpeed = 20;

  final Game game;
  @override
  final List<Combatant> combatants = [];
  final List<BotBrain> _brains = [];
  @override
  final List<LootItem> loot = [];
  @override
  late final SafeZone zone;
  final List<KillFeedEntry> killFeed = [];

  MatchPhase phase = MatchPhase.plane;
  double _nextReport = 15;
  double _nextPrune = 5;
  double matchTime = 0;
  int aliveCount = playerCount;
  Combatant? winner;

  /// Weapon the player is standing on but has no free slot for.
  LootItem? swapCandidate;

  // Plane.
  late final Node _plane;
  final List<Node> _props = [];
  late vm.Vector3 _planeStart, _planeEnd;
  late double _planeDuration;
  double _planeTime = 0;
  late final double planeYaw;

  // Zone wall and loot visuals.
  late final Node _zoneWall;
  final Map<LootItem, Node> _lootNodes = {};
  late final Mesh _glow;
  final Map<Combatant, double> _deathTime = {};

  @override
  CollisionWorld get world => game.world;
  @override
  math.Random get random => game.random;
  @override
  bool get zoneActive => phase == MatchPhase.battle;

  Combatant get player => game.player;
  double get planeProgress => (_planeTime / _planeDuration).clamp(0.0, 1.0);
  vm.Vector3 get planePosition => _planeStart + (_planeEnd - _planeStart) * planeProgress;
  vm.Vector3 get planeVelocity => (_planeEnd - _planeStart).normalized() * planeSpeed;
  bool get planeFlying => _planeTime < _planeDuration;
  int get aboardCount => combatants.where((c) => c.controller.mode == MoveMode.plane).length;

  // ------------------------------------------------------------------ setup

  void setUp() {
    _setUpPlane();
    loot.addAll(generateLoot(world, random));
    zone = SafeZone(
      center: vm.Vector2.zero(),
      radius: 150,
      phases: SafeZone.defaultPhases,
      random: random,
      isGoodCenter: (p) => world.terrainHeight(p.x, p.y) > world.seaLevel + 1.5,
    );
    _setUpZoneWall();

    combatants.add(player);
    player.controller.mode = MoveMode.plane;
    if (game.autopilot) _brains.add(_brainFor(player, 0.6));
    final skills = List.generate(playerCount - 1, (i) => 0.15 + 0.8 * (i / (playerCount - 2)))..shuffle(random);
    for (var i = 1; i < playerCount; i++) {
      final bot = game.createCombatant(
        id: i,
        name: _botName(i),
        isPlayer: false,
        model: game.assets.botSoldiers[i % game.assets.botSoldiers.length],
        spawn: planePosition,
      );
      bot.controller.mode = MoveMode.plane;
      combatants.add(bot);
      _brains.add(_brainFor(bot, skills[i - 1]));
    }
    final glowMaterial = UnlitMaterial()
      ..baseColorFactor = vm.Vector4(1, 0.85, 0.3, 0.45)
      ..alphaMode = AlphaMode.blend;
    _glow = Mesh(DiscGeometry(radius: 0.45, segments: 20), glowMaterial);
    for (final item in loot) {
      _addLootNode(item);
    }
  }

  BotBrain _brainFor(Combatant c, double skill) {
    final brain = BotBrain(c, this, skill: skill);
    brain.dropTarget = _pickDropTarget();
    // Jump when the plane passes closest to the drop target.
    final path = _planeEnd - _planeStart;
    final along = (vm.Vector3(brain.dropTarget.x, 0, brain.dropTarget.y) - _planeStart).dot(path) / path.length2;
    brain.jumpAt = (along + (random.nextDouble() - 0.5) * 0.08).clamp(0.04, 0.95);
    return brain;
  }

  void _log(String message) => debugPrint('[match ${matchTime.toStringAsFixed(1)}s] $message');

  void _setUpPlane() {
    // Fly straight across the island on a random heading, near the middle.
    final angle = random.nextDouble() * math.pi * 2;
    final dir = vm.Vector3(math.sin(angle), 0, math.cos(angle));
    final side = vm.Vector3(dir.z, 0, -dir.x) * ((random.nextDouble() - 0.5) * 60);
    _planeStart = -dir * 190 + side + vm.Vector3(0, planeAltitude, 0);
    _planeEnd = dir * 190 + side + vm.Vector3(0, planeAltitude, 0);
    _planeDuration = (_planeEnd - _planeStart).length / planeSpeed;
    planeYaw = angle;

    _plane = game.assets.airplane.clone();
    for (var i = 0; i < 4; i++) {
      final prop = _plane.getChildByName('Prop$i');
      if (prop != null) _props.add(prop);
    }
    // The model's nose is -Z after import; face it along the flight path.
    final holder = Node()..add(_plane);
    _plane.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), math.pi);
    game.scene.add(holder);
    _planeHolder = holder;
    _updatePlane(0);
  }

  late final Node _planeHolder;

  void _setUpZoneWall() {
    final material = UnlitMaterial()
      ..baseColorFactor = vm.Vector4(0.25, 0.55, 1.0, 0.2)
      ..alphaMode = AlphaMode.blend
      ..doubleSided = true;
    final geometry = CylinderGeometry(bottomRadius: 1, topRadius: 1, height: 1, radialSegments: 72, bottomCap: false, topCap: false);
    _zoneWall = Node(mesh: Mesh(geometry, material))..castsShadows = false;
    game.scene.add(_zoneWall);
  }

  vm.Vector2 _pickDropTarget() {
    // Most bots head for buildings (loot), the rest for random open ground.
    if (random.nextDouble() < 0.35 && loot.isNotEmpty) {
      final item = loot[random.nextInt(loot.length)];
      return vm.Vector2(item.position.x, item.position.z);
    }
    for (var i = 0; i < 30; i++) {
      final p = vm.Vector2((random.nextDouble() - 0.5) * 180, (random.nextDouble() - 0.5) * 180);
      if (world.terrainHeight(p.x, p.y) > world.seaLevel + 1.5) return p;
    }
    return vm.Vector2.zero();
  }

  static const _names = [
    'Viper', 'Ghost', 'Blaze', 'Raven', 'Titan', 'Nova', 'Rex', 'Kira', 'Zed', 'Storm',
    'Hawk', 'Shadow', 'Frost', 'Ace', 'Jinx', 'Bolt', 'Rogue', 'Echo', 'Fang', 'Onyx',
    'Pixel', 'Sniper', 'Tank', 'Lynx', 'Dash', 'Cobra', 'Maverick', 'Saber', 'Zero', 'Atlas',
  ];

  String _botName(int i) => '${_names[i % _names.length]}${10 + (i * 37) % 89}';

  void _addLootNode(LootItem item) {
    final model = switch (item.kind) {
      LootKind.weapon => game.assets.lowGuns[item.weapon!.id]!.clone()
        // Lie the gun on its side.
        ..rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), math.pi / 2)
        ..position = vm.Vector3(0, 0.05, 0),
      LootKind.medkit => game.assets.medkit.clone(),
      LootKind.ammo => game.assets.ammoBox.clone(),
    };
    final node = Node()
      ..position = item.position + vm.Vector3(0, 0.02, 0)
      ..add(Node(mesh: _glow)..castsShadows = false)
      ..add(Node()..add(model));
    game.scene.add(node);
    _lootNodes[item] = node;
  }

  void _dropLoot(vm.Vector3 at, LootItem Function(vm.Vector3 at) make) {
    final a = random.nextDouble() * math.pi * 2;
    final p = vm.Vector3(at.x + math.cos(a) * 0.7, 0, at.z + math.sin(a) * 0.7);
    p.y = world.groundHeight(p.x, p.z, at.y);
    final item = make(p);
    loot.add(item);
    _addLootNode(item);
  }

  void _take(LootItem item) {
    item.taken = true;
    _lootNodes.remove(item)?.detach();
  }

  // ------------------------------------------------------------------ tick

  void tick(double dt) {
    matchTime += dt;
    _planeTime += dt;
    _updatePlane(dt);

    // Jumps: bots at their planned moment, everyone when the plane leaves.
    for (final brain in _brains) {
      final c = brain.bot.controller;
      if (c.mode == MoveMode.plane && (planeProgress >= brain.jumpAt || !planeFlying)) {
        c.exitPlane(planePosition + vm.Vector3(0, -3, 0), planeVelocity);
      }
    }
    if (player.controller.mode == MoveMode.plane && planeProgress >= 0.97) playerJump();

    if (phase == MatchPhase.plane && !planeFlying) {
      phase = MatchPhase.battle;
      _planeHolder.visible = false;
      _log('plane gone, zone timer started; ${loot.length} loot items');
    }
    if (matchTime >= _nextReport) {
      _nextReport += 15;
      final landed = combatants.where((c) => c.alive && c.onGround).length;
      final armed = combatants.where((c) => c.alive && c.armed).length;
      _log('alive $aliveCount, on ground $landed, armed $armed, zone r=${zone.radius.toStringAsFixed(0)} phase ${zone.phase}');
    }
    if (phase == MatchPhase.battle) zone.update(dt);

    for (final brain in _brains) {
      brain.update(dt);
    }
    for (final c in combatants) {
      c.controller.update(dt);
      if (!c.alive) continue;
      c.update(dt);
      if (!c.isPlayer) c.alignGun();
      if (c.onGround) _pickUp(c);
      if (phase == MatchPhase.battle && c.controller.mode != MoveMode.plane && !zone.contains(c.position.x, c.position.z)) {
        if (c.takeDamage(zone.damagePerSecond * dt, null)) onEliminated(c, null, 'Zone', false);
      }
    }
    // Forget picked-up items now and then so the list stays short.
    if (matchTime >= _nextPrune) {
      _nextPrune = matchTime + 5;
      loot.removeWhere((item) => item.taken);
    }
    _updateVisibility(dt);
    _updateZoneWall();
    killFeed.removeWhere((e) => matchTime - e.time > 6);
  }

  void _updatePlane(double dt) {
    _planeHolder.position = planePosition;
    _planeHolder.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), planeYaw);
    final spin = vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), matchTime * 40);
    for (final prop in _props) {
      prop.rotation = spin;
    }
  }

  void _updateZoneWall() {
    // The first circle covers the whole island; show the wall once it matters.
    _zoneWall.visible = phase != MatchPhase.plane && zone.radius < 140;
    final r = math.max(zone.radius, 0.5);
    _zoneWall.localTransform = vm.Matrix4.compose(
      vm.Vector3(zone.center.x, 40, zone.center.y),
      vm.Quaternion.identity(),
      vm.Vector3(r, 180, r),
    );
  }

  /// Hides far-away soldiers and loot (the fog hides them anyway) and
  /// removes bodies after a while, to keep the draw count down.
  void _updateVisibility(double dt) {
    final eye = game.eye;
    for (final c in combatants) {
      if (c.isPlayer) continue;
      final mode = c.controller.mode;
      var show = mode != MoveMode.plane && c.position.distanceTo(eye) < 160;
      if (!c.alive && matchTime - (_deathTime[c] ?? matchTime) > 8) show = false;
      c.controller.node.visible = show;
    }
    final spin = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), matchTime * 0.8);
    for (final entry in _lootNodes.entries) {
      final near = entry.key.position.distanceTo(eye) < 45;
      entry.value.visible = near;
      if (near) entry.value.children[1].rotation = spin;
    }
  }

  // ------------------------------------------------------------------ loot

  void _pickUp(Combatant c) {
    if (c.isPlayer) swapCandidate = null;
    // Index loop over the current length: swapping drops the old gun into
    // [loot] while we are walking it.
    for (var i = 0, n = loot.length; i < n; i++) {
      final item = loot[i];
      if (item.taken) continue;
      final dx = item.position.x - c.position.x, dz = item.position.z - c.position.z;
      if (dx * dx + dz * dz > 1.3 * 1.3 || (item.position.y - c.position.y).abs() > 1.5) continue;
      switch (item.kind) {
        case LootKind.weapon:
          final spec = item.weapon!;
          if (c.hasWeapon(spec) || c.slots.contains(null)) {
            c.giveWeapon(spec, ammo: item.ammo, reserve: item.reserve);
            _take(item);
          } else if (c.isPlayer) {
            swapCandidate = item;
          } else if (_rank(spec) > _rank(c.weapon!.spec)) {
            _swap(c, item);
          }
        case LootKind.medkit:
          if (c.medkits < Combatant.maxMedkits) {
            c.medkits++;
            _take(item);
          }
        case LootKind.ammo:
          if (c.armed) {
            c.addAmmo();
            _take(item);
          }
      }
    }
  }

  static int _rank(WeaponSpec spec) => switch (spec.id) {
    'assault_rifle' => 5,
    'machine_gun' => 4,
    'shotgun' => 3,
    'sniper_rifle' => 2,
    _ => 1,
  };

  void _swap(Combatant c, LootItem item) {
    final dropped = c.giveWeapon(item.weapon!, ammo: item.ammo, reserve: item.reserve, replace: true);
    _take(item);
    if (dropped != null) {
      _dropLoot(c.position, (p) => LootItem(LootKind.weapon, p, weapon: dropped.spec, ammo: dropped.ammo, reserve: dropped.reserve));
    }
  }

  void playerSwap() {
    final item = swapCandidate;
    if (item == null || item.taken || !player.alive) return;
    _swap(player, item);
    swapCandidate = null;
  }

  void playerJump() {
    final c = player.controller;
    if (c.mode != MoveMode.plane) return;
    c.exitPlane(planePosition + vm.Vector3(0, -3, 0), planeVelocity);
  }

  // ------------------------------------------------------------------ combat

  @override
  bool fire(Combatant shooter, vm.Vector3 dir) => game.fireWeapon(shooter, shooter.eye, dir);

  /// Gunfire carries: bots within earshot come to investigate.
  void onShot(Combatant shooter) {
    for (final brain in _brains) {
      if (brain.bot.alive && brain.bot.position.distanceTo(shooter.position) < 90) brain.hearShot(shooter);
    }
  }

  void onEliminated(Combatant victim, Combatant? killer, String weapon, bool headshot) {
    victim.placement = aliveCount;
    aliveCount--;
    _deathTime[victim] = matchTime;
    if (killer != null && !identical(killer, victim)) killer.kills++;
    killFeed.add(KillFeedEntry(killer?.name, victim.name, weapon, headshot, matchTime));
    if (killFeed.length > 5) killFeed.removeAt(0);

    // Drop everything they carried.
    for (final s in victim.slots) {
      if (s != null) {
        _dropLoot(victim.position, (p) => LootItem(LootKind.weapon, p, weapon: s.spec, ammo: s.ammo, reserve: s.reserve));
      }
    }
    if (victim.medkits > 0) _dropLoot(victim.position, (p) => LootItem(LootKind.medkit, p));
    if (victim.isPlayer) swapCandidate = null;

    _log('${killer?.name ?? 'Zone'} eliminated ${victim.name} with $weapon${headshot ? ' (headshot)' : ''}; $aliveCount left');
    if (aliveCount <= 1) {
      winner = combatants.firstWhere((c) => c.alive, orElse: () => killer ?? victim);
      winner!.placement = 1;
      phase = MatchPhase.ended;
      _log('WINNER ${winner!.name} with ${winner!.kills} kills');
    }
  }

  /// Who the dead player's camera follows: the killer, else anyone alive.
  Combatant spectateTarget(Combatant dead) {
    final killer = dead.lastAttacker;
    if (killer != null && killer.alive) return killer;
    return combatants.firstWhere((c) => c.alive, orElse: () => dead);
  }
}
