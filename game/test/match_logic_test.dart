import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:combat_game/game/collision_world.dart';
import 'package:combat_game/game/loot.dart';
import 'package:combat_game/game/zone.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  group('SafeZone', () {
    SafeZone zone([int seed = 1]) => SafeZone(
      center: vm.Vector2.zero(),
      radius: 150,
      phases: SafeZone.defaultPhases,
      random: math.Random(seed),
    );

    test('every next circle sits inside the current one', () {
      for (var seed = 0; seed < 20; seed++) {
        final z = zone(seed);
        while (!z.finished) {
          final from = z.center.clone(), fromRadius = z.radius;
          expect((z.nextCenter - from).length + z.nextRadius, lessThanOrEqualTo(fromRadius + 1e-6));
          z.update(1);
          while (!z.finished && z.shrinking) {
            z.update(1);
          }
        }
      }
    });

    test('waits, then shrinks to the target radius on schedule', () {
      final z = zone();
      final first = SafeZone.defaultPhases.first;
      z.update(first.waitSeconds - 1);
      expect(z.shrinking, isFalse);
      expect(z.radius, 150);
      z.update(2);
      expect(z.shrinking, isTrue);
      z.update(first.shrinkSeconds);
      expect(z.phase, 1);
      expect(z.radius, closeTo(first.radius, 1e-6));
    });

    test('ends at radius zero', () {
      final z = zone();
      for (var t = 0; t < 1000 && !z.finished; t++) {
        z.update(1);
      }
      expect(z.finished, isTrue);
      expect(z.radius, closeTo(0, 1e-6));
    });
  });

  test('loot lands on solid ground with enough guns for everyone', () {
    final json = File('assets/models/training_island.collision.json').readAsStringSync();
    final world = CollisionWorld.fromJson(jsonDecode(json) as Map<String, dynamic>);
    final loot = generateLoot(world, math.Random(7));
    final guns = loot.where((l) => l.kind == LootKind.weapon).length;
    expect(guns, greaterThanOrEqualTo(50));
    for (final item in loot) {
      final p = item.position;
      expect(world.terrainHeight(p.x, p.z), greaterThan(world.seaLevel), reason: 'item in the sea at $p');
      // Resting on the ground or a floor, not floating or buried.
      expect(world.groundHeight(p.x, p.z, p.y), closeTo(p.y, 0.01), reason: 'item not on a surface at $p');
    }
  });
}
