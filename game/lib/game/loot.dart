import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;

import 'collision_world.dart';
import 'weapons.dart';

enum LootKind { weapon, medkit, ammo }

/// Something lying on the ground to pick up.
class LootItem {
  LootItem(this.kind, this.position, {this.weapon, this.ammo = 0, this.reserve = 0});

  final LootKind kind;
  final vm.Vector3 position;

  /// For weapons: which gun, and the rounds it carries.
  final WeaponSpec? weapon;
  final int ammo;
  final int reserve;
  bool taken = false;

  /// Set by the renderer.
  Object? visual;

  String get label => switch (kind) {
    LootKind.weapon => weapon!.name,
    LootKind.medkit => 'Medkit',
    LootKind.ammo => 'Ammo',
  };
}

/// Scatters loot over the island: a few items on every reachable floor
/// (houses, warehouse) and the rest on open ground.
List<LootItem> generateLoot(CollisionWorld world, math.Random random, {int outdoor = 85}) {
  final items = <LootItem>[];

  LootItem roll(vm.Vector3 at) {
    // Weighted table: rifles are common, snipers rare.
    final r = random.nextDouble();
    final String? gun = r < 0.17
        ? 'assault_rifle'
        : r < 0.25
        ? 'machine_gun'
        : r < 0.39
        ? 'shotgun'
        : r < 0.46
        ? 'sniper_rifle'
        : r < 0.62
        ? 'pistol'
        : null;
    if (gun != null) {
      final spec = weaponSpecs.firstWhere((s) => s.id == gun);
      return LootItem(LootKind.weapon, at, weapon: spec, ammo: spec.magazine, reserve: spec.magazine * 2);
    }
    return LootItem(r < 0.82 ? LootKind.medkit : LootKind.ammo, at);
  }

  // Floors: thin, wide slabs the player can stand on (not the tower top).
  for (final b in world.boxes) {
    final terrain = world.terrainHeight(b.center.x, b.center.z);
    final heightAbove = b.top - terrain;
    if (b.halfExtents.y > 0.16 || b.halfExtents.x < 1.8 || b.halfExtents.z < 1.8) continue;
    if (heightAbove < 0.05 || heightAbove > 4) continue;
    final count = 2 + random.nextInt(3);
    for (var i = 0; i < count; i++) {
      final lx = (random.nextDouble() * 2 - 1) * (b.halfExtents.x - 0.7);
      final lz = (random.nextDouble() * 2 - 1) * (b.halfExtents.z - 0.7);
      final x = b.center.x + b.worldX(lx, lz), z = b.center.z + b.worldZ(lx, lz);
      // Skip spots under a wall or shelf standing on this floor.
      if (world.boxes.any((o) => o != b && o.bottom < b.top + 1 && o.top > b.top + 0.3 && o.containsXZ(x, z, 0.3))) continue;
      // Rest on whatever is there (a stair step or crate on the floor).
      items.add(roll(vm.Vector3(x, world.groundHeight(x, z, b.top), z)));
    }
  }

  // Open ground.
  var attempts = 0;
  var placed = 0;
  while (placed < outdoor && attempts++ < outdoor * 30) {
    final x = (random.nextDouble() - 0.5) * world.size * 0.8;
    final z = (random.nextDouble() - 0.5) * world.size * 0.8;
    final h = world.terrainHeight(x, z);
    if (h < world.seaLevel + 1.2) continue;
    if (world.boxes.any((b) => b.containsXZ(x, z, 0.5))) continue;
    if (world.circles.any((c) => (c.x - x) * (c.x - x) + (c.z - z) * (c.z - z) < (c.radius + 0.5) * (c.radius + 0.5))) continue;
    items.add(roll(vm.Vector3(x, h, z)));
    placed++;
  }
  return items;
}
