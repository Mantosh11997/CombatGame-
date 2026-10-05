import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'character_controller.dart';
import 'weapons.dart';

/// A soldier in the match: the player or an AI. Both use exactly the same
/// rules for health, guns, ammo, healing and damage.
class Combatant {
  Combatant({
    required this.id,
    required this.name,
    required this.isPlayer,
    required this.controller,
    required this.socket,
    required this.gunModel,
    int slotCount = 2,
  }) : slots = List.filled(slotCount, null),
       _gunNodes = List.filled(slotCount, null),
       _muzzles = List.filled(slotCount, null);

  static const double maxHealth = 100;
  static const int maxMedkits = 5;
  static const double healAmount = 75;
  static const double healTime = 2.5;

  final int id;
  final String name;
  final bool isPlayer;
  final CharacterController controller;

  /// Right-hand attachment point on the soldier model.
  final Node socket;

  /// Builds the gun model to hold (full detail for the player, low for bots).
  final Node Function(WeaponSpec spec) gunModel;

  double health = maxHealth;
  final List<WeaponState?> slots;
  final List<Node?> _gunNodes;
  final List<Node?> _muzzles;
  int current = 0;
  int medkits = 0;
  int kills = 0;
  double _healLeft = 0;

  /// Vertical aim, used to tilt the held gun.
  double aimPitch = 0;

  /// Who last hurt this soldier, for the kill feed.
  Combatant? lastAttacker;
  double hurtTime = 0;

  /// Rank when eliminated (1 = winner).
  int? placement;

  bool get alive => health > 0;
  vm.Vector3 get position => controller.position;
  vm.Vector3 get eye => controller.position + vm.Vector3(0, 1.55, 0);
  vm.Vector3 get chest => controller.position + vm.Vector3(0, 1.2, 0);
  WeaponState? get weapon => slots[current];
  bool get armed => weapon != null;
  bool get healing => _healLeft > 0;
  double get healProgress => healing ? 1 - _healLeft / healTime : 0;
  bool get onGround => controller.mode == MoveMode.ground;

  bool hasWeapon(WeaponSpec spec) => slots.any((s) => s?.spec.id == spec.id);

  /// Picks up a gun. Fills an empty slot, adds ammo to the same gun, or (when
  /// [replace]) swaps out the current gun, which is returned to be dropped.
  WeaponState? giveWeapon(WeaponSpec spec, {int? ammo, int? reserve, bool replace = false}) {
    final same = slots.indexWhere((s) => s?.spec.id == spec.id);
    if (same >= 0) {
      slots[same]!.reserve += (ammo ?? spec.magazine) + (reserve ?? 0);
      return null;
    }
    var slot = slots.indexWhere((s) => s == null);
    WeaponState? dropped;
    if (slot < 0) {
      if (!replace) return null;
      slot = current;
      dropped = slots[slot];
    }
    final state = WeaponState(spec);
    if (ammo != null) state.ammo = ammo;
    if (reserve != null) state.reserve = reserve;
    slots[slot] = state;
    _gunNodes[slot]?.detach();
    final holder = Node()..add(gunModel(spec));
    socket.add(holder);
    _gunNodes[slot] = holder;
    _muzzles[slot] = holder.getChildByName('Muzzle');
    if (slots[current] == null || slot == current || dropped != null) current = slot;
    _refreshGuns();
    return dropped;
  }

  void selectSlot(int slot) {
    if (slot < 0 || slot >= slots.length || slots[slot] == null || slot == current) return;
    weapon?.cancelReload();
    _healLeft = 0;
    current = slot;
    _refreshGuns();
  }

  /// Switches to the next carried gun.
  void cycleWeapon() {
    for (var i = 1; i < slots.length; i++) {
      final slot = (current + i) % slots.length;
      if (slots[slot] != null) return selectSlot(slot);
    }
  }

  void _refreshGuns() {
    for (var i = 0; i < _gunNodes.length; i++) {
      _gunNodes[i]?.visible = i == current;
    }
    controller.armed = armed;
  }

  /// Every held gun gets one more magazine in reserve.
  void addAmmo() {
    for (final s in slots) {
      if (s != null) s.reserve += s.spec.magazine;
    }
  }

  bool startHeal() {
    if (healing || medkits == 0 || health >= maxHealth || !alive) return false;
    weapon?.cancelReload();
    _healLeft = healTime;
    return true;
  }

  void cancelHeal() => _healLeft = 0;

  void update(double dt) {
    hurtTime += dt;
    for (final s in slots) {
      s?.update(s == weapon ? dt : 0);
    }
    if (_healLeft > 0) {
      _healLeft -= dt;
      if (_healLeft <= 0) {
        _healLeft = 0;
        medkits--;
        health = math.min(maxHealth, health + healAmount);
      }
    }
  }

  /// Applies damage. Returns true when this hit eliminated the soldier.
  bool takeDamage(double amount, Combatant? attacker) {
    if (!alive) return false;
    health -= amount;
    hurtTime = 0;
    if (attacker != null) lastAttacker = attacker;
    if (health <= 0) {
      health = 0;
      _healLeft = 0;
      controller.die();
      for (final n in _gunNodes) {
        n?.visible = false;
      }
      return true;
    }
    return false;
  }

  /// Muzzle position of the held gun, or the hand when unarmed.
  vm.Vector3 get muzzle =>
      (_muzzles[current] ?? socket).globalTransform.getTranslation();

  /// Keeps the held gun pointing along the body's facing, tilted with the aim,
  /// whatever the animated hand is doing.
  void alignGun() {
    final holder = _gunNodes[current];
    if (holder == null || !alive) return;
    final socketRotation = socket.globalTransform.getRotation()..transpose();
    final desired = vm.Matrix3.rotationY(controller.yaw + math.pi) * vm.Matrix3.rotationX(aimPitch);
    holder.rotation = vm.Quaternion.fromRotation(socketRotation * desired);
  }

  /// Ray hit test against this soldier: (distance, headshot) or null.
  (double, bool)? raycast(vm.Vector3 origin, vm.Vector3 dir, double maxT) {
    if (!alive || controller.mode == MoveMode.plane) return null;
    final base = position;
    double? best;
    var head = false;
    final th = _raySphere(origin, dir, base + vm.Vector3(0, 1.63, 0), 0.15);
    if (th != null && th < maxT) {
      best = th;
      head = true;
    }
    final tb = _rayCylinder(origin, dir, base, 0.32, 0.05, 1.48);
    if (tb != null && tb < (best ?? maxT)) {
      best = tb;
      head = false;
    }
    return best == null ? null : (best, head);
  }

  static double? _raySphere(vm.Vector3 o, vm.Vector3 d, vm.Vector3 c, double r) {
    final oc = o - c;
    final b = oc.dot(d);
    final cc = oc.dot(oc) - r * r;
    final disc = b * b - cc;
    if (disc < 0) return null;
    final t = -b - math.sqrt(disc);
    return t > 0 ? t : null;
  }

  static double? _rayCylinder(vm.Vector3 o, vm.Vector3 d, vm.Vector3 base, double r, double y0, double y1) {
    final ox = o.x - base.x, oz = o.z - base.z;
    final a = d.x * d.x + d.z * d.z;
    if (a < 1e-9) return null;
    final b = 2 * (ox * d.x + oz * d.z);
    final c = ox * ox + oz * oz - r * r;
    final disc = b * b - 4 * a * c;
    if (disc < 0) return null;
    final t = (-b - math.sqrt(disc)) / (2 * a);
    if (t <= 0) return null;
    final y = o.y + d.y * t - base.y;
    return y >= y0 && y <= y1 ? t : null;
  }
}
