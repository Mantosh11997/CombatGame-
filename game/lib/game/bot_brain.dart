import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;

import 'character_controller.dart';
import 'collision_world.dart';
import 'combatant.dart';
import 'loot.dart';
import 'weapons.dart';
import 'zone.dart';

/// What a bot can ask of the match it is playing in.
abstract class BattleContext {
  CollisionWorld get world;
  List<Combatant> get combatants;
  List<LootItem> get loot;
  SafeZone get zone;
  bool get zoneActive;
  math.Random get random;

  /// Fires [shooter]'s current gun from its eye along [dir], if it can fire.
  bool fire(Combatant shooter, vm.Vector3 dir);
}

/// Drives one AI soldier by setting the same inputs the player's controls
/// set: a move direction, sprint, facing, trigger, reload, weapon switch,
/// medkit. It plays by the player's rules: same guns, same spread, same
/// damage, and it has to see an enemy (line of sight) to shoot at it.
class BotBrain {
  BotBrain(this.bot, this.ctx, {required this.skill})
    : _thinkTimer = ctx.random.nextDouble() * 0.25;

  final Combatant bot;
  final BattleContext ctx;

  /// 0 (sloppy) .. 1 (sharp): reaction time, aim speed and accuracy.
  final double skill;

  /// Where this bot wants to land, and when (plane progress 0..1) it jumps.
  vm.Vector2 dropTarget = vm.Vector2.zero();
  double jumpAt = 0.5;

  Combatant? _enemy;
  bool _enemyVisible = false;
  vm.Vector3? _lastSeen;
  double _sinceSeen = 99;
  double _reaction = 0;
  vm.Vector2? _goal;
  bool _goalIsLoot = false;
  vm.Vector2? _wander;
  double _wanderAge = 0;
  double _thinkTimer;
  double _stuckTime = 0;
  double _detourTime = 0;
  double _detourAngle = 0;
  double _strafe = 1;
  double _strafeTime = 0;
  double _burstLeft = 0;
  double _burstPause = 0;
  double _aimYaw = 0;
  double _aimPitch = 0;

  CharacterController get _c => bot.controller;

  void update(double dt) {
    if (!bot.alive) return;
    switch (_c.mode) {
      case MoveMode.plane:
      case MoveMode.dead:
        return;
      case MoveMode.freefall:
      case MoveMode.parachute:
        _steerDescent();
        return;
      case MoveMode.ground:
        break;
    }

    _sinceSeen += dt;
    _wanderAge += dt;
    _thinkTimer -= dt;
    if (_thinkTimer <= 0) {
      _thinkTimer = 0.25;
      _think();
    }
    _move(dt);
    _combat(dt);
  }

  // ------------------------------------------------------------------ descent

  void _steerDescent() {
    final to = dropTarget - vm.Vector2(_c.position.x, _c.position.z);
    final dist = to.length;
    // Open early to glide further when the drop spot is still far away.
    if (_c.canOpenParachute && dist > 22) _c.openParachute();
    _c.cameraYaw = 0;
    _c.sprint = false;
    _c.faceYaw = null;
    _c.moveInput = dist > 2 ? vm.Vector2(to.x / dist, to.y / dist) : vm.Vector2.zero();
  }

  // ------------------------------------------------------------------ thinking

  void _think() {
    _lookForEnemy();
    _goal = null;
    _goalIsLoot = false;

    // 1. Get inside the safe zone before anything else when outside it.
    final zone = ctx.zone;
    final pos = vm.Vector2(_c.position.x, _c.position.z);
    if (ctx.zoneActive) {
      final target = zone.shrinking ? zone.nextCenter : zone.center;
      final radius = zone.shrinking ? zone.nextRadius : zone.radius;
      if ((pos - zone.center).length > zone.radius * 0.92 ||
          (zone.shrinking && (pos - target).length > radius * 0.85)) {
        _goal = target;
        return;
      }
    }

    // 2. In a fight: the combat code steers.
    if (_enemyVisible && bot.armed) return;

    // 3. Heal when it is quiet.
    if (bot.health < 60 && bot.medkits > 0 && _sinceSeen > 3) {
      bot.startHeal();
      return;
    }

    // 4. Chase the last place an enemy was seen.
    if (bot.armed && _lastSeen != null && _sinceSeen < 4) {
      _goal = vm.Vector2(_lastSeen!.x, _lastSeen!.z);
      return;
    }

    // 5. Loot: guns first, then medkits and ammo.
    final item = _wantedLoot(pos, bot.armed ? 40 : double.infinity);
    if (item != null) {
      _goal = vm.Vector2(item.position.x, item.position.z);
      _goalIsLoot = true;
      return;
    }

    // 6. Wander somewhere inside the zone.
    if (_wander == null || (_wander! - pos).length < 3 || _wanderAge > 20) {
      _wander = _randomPointInZone();
      _wanderAge = 0;
    }
    _goal = _wander;
  }

  void _lookForEnemy() {
    final range = bot.armed ? (bot.weapon!.spec.id == 'sniper_rifle' ? 70.0 : 40.0) : 20.0;
    // Still gearing up: only fight what is close or already shooting at us.
    final gearingUp = bot.slots.contains(null) || bot.medkits == 0;
    final underFire = bot.hurtTime < 2 && bot.lastAttacker?.alive == true;
    final facing = CharacterController.headingForward(_c.yaw);
    final candidates = <(double, Combatant)>[];
    for (final other in ctx.combatants) {
      // Only soldiers on the ground: nobody shoots people still in the air.
      if (identical(other, bot) || !other.alive || !other.onGround) continue;
      final d = other.position.distanceTo(_c.position);
      if (d >= range) continue;
      if (gearingUp && d > 15 && !(underFire && identical(other, bot.lastAttacker))) continue;
      // Field of view: ~150 degrees ahead, but anyone very close is noticed.
      final to = other.position - _c.position;
      final ahead = (to.x * facing.x + to.z * facing.z) / math.max(d, 1e-3);
      // Being shot gives the attacker away, wherever they are.
      final attacker = underFire && identical(other, bot.lastAttacker);
      if (d > 10 && ahead < math.cos(75 * math.pi / 180) && !identical(other, _enemy) && !attacker) continue;
      candidates.add((d, other));
    }
    candidates.sort((a, b) => a.$1.compareTo(b.$1));
    final wasVisible = _enemyVisible;
    final previous = _enemy;
    _enemyVisible = false;
    // Line-of-sight checks are the expensive part: test at most two.
    for (final (d, other) in candidates.take(2)) {
      final from = bot.eye, to = other.chest;
      final dir = to - from;
      final hit = ctx.world.raycast(from, dir / d, d);
      if (hit == null || hit.distance > d - 0.6) {
        _enemy = other;
        _enemyVisible = true;
        _lastSeen = other.position.clone();
        _sinceSeen = 0;
        if (!wasVisible || !identical(previous, other)) {
          // Takes a moment to react to a newly spotted enemy.
          _reaction = (0.5 + ctx.random.nextDouble() * 0.7) * (1.5 - skill);
        }
        bot.cancelHeal();
        break;
      }
    }
  }

  LootItem? _wantedLoot(vm.Vector2 pos, double maxDistance) {
    LootItem? best;
    var bestScore = double.infinity;
    final freeSlot = bot.slots.contains(null);
    for (final item in ctx.loot) {
      if (item.taken) continue;
      final d = (vm.Vector2(item.position.x, item.position.z) - pos).length;
      if (d > maxDistance) continue;
      final want = switch (item.kind) {
        LootKind.weapon => freeSlot && !bot.hasWeapon(item.weapon!) ? 1.0 : 0.0,
        LootKind.medkit => bot.medkits < 3 ? 0.6 : 0.0,
        LootKind.ammo => bot.armed && bot.weapon!.reserve < bot.weapon!.spec.magazine ? 0.5 : 0.0,
      };
      if (want == 0) continue;
      final score = d / want;
      if (score < bestScore) {
        bestScore = score;
        best = item;
      }
    }
    return best;
  }

  vm.Vector2 _randomPointInZone() {
    final zone = ctx.zone;
    final center = ctx.zoneActive && zone.shrinking ? zone.nextCenter : zone.center;
    final radius = math.max(4.0, (ctx.zoneActive && zone.shrinking ? zone.nextRadius : zone.radius) * 0.7);
    for (var i = 0; i < 12; i++) {
      final a = ctx.random.nextDouble() * math.pi * 2;
      final r = math.sqrt(ctx.random.nextDouble()) * radius;
      final p = center + vm.Vector2(math.cos(a), math.sin(a)) * r;
      if (ctx.world.terrainHeight(p.x, p.y) > ctx.world.seaLevel + 0.8) return p;
    }
    return center.clone();
  }

  /// A gunshot nearby: go and look, unless already busy with a visible enemy.
  void hearShot(Combatant shooter) {
    if (_enemyVisible || !bot.armed || identical(shooter, bot)) return;
    _lastSeen = shooter.position.clone();
    _sinceSeen = 0;
  }

  // ------------------------------------------------------------------ moving

  void _move(double dt) {
    _c.cameraYaw = 0;
    if (bot.healing) {
      _c.moveInput = vm.Vector2.zero();
      return;
    }

    vm.Vector2 desire = vm.Vector2.zero();
    final pos = vm.Vector2(_c.position.x, _c.position.z);
    final enemy = _enemy;
    final fighting = _enemyVisible && bot.armed && enemy != null && enemy.alive;

    if (fighting) {
      // Keep a comfortable range for the gun in hand and strafe.
      final spec = bot.weapon!.spec;
      final preferred = switch (spec.id) {
        'shotgun' => 6.0,
        'sniper_rifle' => 45.0,
        'pistol' => 12.0,
        _ => 18.0,
      };
      final to = vm.Vector2(enemy.position.x - pos.x, enemy.position.z - pos.y);
      final d = to.length;
      final toward = d > 0.01 ? to / d : vm.Vector2(0, 1);
      final side = vm.Vector2(-toward.y, toward.x);
      _strafeTime -= dt;
      if (_strafeTime <= 0) {
        _strafe = ctx.random.nextBool() ? 1 : -1;
        _strafeTime = 0.6 + ctx.random.nextDouble() * 1.2;
      }
      final approach = ((d - preferred) / preferred).clamp(-1.0, 1.0);
      desire = toward * approach + side * (_strafe * 0.8);
      if (_goal != null) {
        // The zone still matters mid-fight.
        final z = _goal! - pos;
        if (z.length > 1) desire += z.normalized() * 0.8;
      }
    } else if (_goal != null) {
      final to = _goal! - pos;
      final d = to.length;
      if (d > (_goalIsLoot ? 0.3 : 1.5)) desire = to / d;
    }

    // Unstick: if trying to move but not getting anywhere, detour sideways.
    final trying = desire.length > 0.3;
    if (trying && _c.horizontalSpeed < 0.6) {
      _stuckTime += dt;
    } else {
      _stuckTime = math.max(0, _stuckTime - dt);
    }
    if (_stuckTime > 0.6 && _detourTime <= 0) {
      _detourTime = 0.8 + ctx.random.nextDouble() * 0.8;
      _detourAngle = (ctx.random.nextBool() ? 1 : -1) * (1.0 + ctx.random.nextDouble() * 0.8);
      if (ctx.random.nextDouble() < 0.4) _c.jump();
      _stuckTime = 0;
    }
    if (_detourTime > 0) {
      _detourTime -= dt;
      final c = math.cos(_detourAngle), s = math.sin(_detourAngle);
      desire = vm.Vector2(desire.x * c - desire.y * s, desire.x * s + desire.y * c);
    }

    _c.moveInput = desire.length > 1 ? desire.normalized() : desire;
    _c.sprint = !fighting && _goal != null && (_goal! - pos).length > 10;
  }

  // ------------------------------------------------------------------ combat

  void _combat(double dt) {
    final enemy = _enemy;
    if (enemy == null || !enemy.alive || !_enemyVisible || !bot.armed) {
      _c.faceYaw = null;
      _burstLeft = 0;
      if (bot.armed && !_enemyVisible && bot.weapon!.ammo < bot.weapon!.spec.magazine * 0.5) {
        bot.weapon!.startReload();
      }
      if (enemy != null && !enemy.alive) _enemy = null;
      return;
    }

    final to = enemy.chest - bot.eye;
    final distance = to.length;

    // Pick the right gun for the range.
    final other = bot.slots[(bot.current + 1) % bot.slots.length];
    if (other != null && !bot.weapon!.reloading) {
      final better = _gunScore(other.spec, distance) > _gunScore(bot.weapon!.spec, distance) + 0.3;
      if (better || bot.weapon!.ammo + bot.weapon!.reserve == 0) bot.cycleWeapon();
    }

    // Turn toward the target at a skill-dependent rate.
    final wantYaw = math.atan2(to.x, to.z);
    final wantPitch = math.atan2(to.y, math.sqrt(to.x * to.x + to.z * to.z));
    final turn = (3 + skill * 5) * dt;
    var dy = wantYaw - _aimYaw;
    dy = math.atan2(math.sin(dy), math.cos(dy));
    _aimYaw += dy.clamp(-turn, turn);
    _aimPitch += (wantPitch - _aimPitch).clamp(-turn, turn);
    _c.faceYaw = _aimYaw;
    bot.aimPitch = _aimPitch;

    _reaction -= dt;
    if (_reaction > 0 || dy.abs() > 0.12) return;
    final spec = bot.weapon!.spec;
    if (distance > spec.range) return;

    // Fire in bursts with short pauses, like a person managing recoil.
    if (_burstPause > 0) {
      _burstPause -= dt;
      return;
    }
    // Aim error: worse for low skill, at range, and while moving.
    final error = (0.08 - 0.045 * skill) + (_c.horizontalSpeed > 1 ? 0.02 : 0);
    final dir = vm.Vector3(
      math.cos(_aimPitch) * math.sin(_aimYaw),
      math.sin(_aimPitch),
      math.cos(_aimPitch) * math.cos(_aimYaw),
    );
    final jitter = vm.Vector3(
      (ctx.random.nextDouble() - 0.5) * 2 * error,
      (ctx.random.nextDouble() - 0.5) * 2 * error,
      (ctx.random.nextDouble() - 0.5) * 2 * error,
    );
    if (_burstLeft <= 0) _burstLeft = 3 + ctx.random.nextInt(5).toDouble();
    if (ctx.fire(bot, (dir + jitter)..normalize())) {
      if (spec.automatic) {
        _burstLeft--;
        if (_burstLeft <= 0) _burstPause = 0.25 + ctx.random.nextDouble() * 0.45;
      } else {
        // Semi-auto: a human can't fire exactly at the cooldown.
        _burstPause = 0.08 + ctx.random.nextDouble() * 0.25;
      }
    }
  }

  static double _gunScore(WeaponSpec spec, double distance) => switch (spec.id) {
    'shotgun' => distance < 10 ? 3 : 0.5,
    'sniper_rifle' => distance > 35 ? 3 : 0.8,
    'machine_gun' => distance < 45 ? 2.2 : 1.2,
    'assault_rifle' => distance < 60 ? 2.4 : 1.5,
    _ => 1,
  };
}
