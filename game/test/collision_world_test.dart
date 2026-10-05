import 'dart:convert';
import 'dart:io';

import 'package:combat_game/game/collision_world.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  late CollisionWorld world;

  setUpAll(() {
    final json = File('assets/models/training_island.collision.json').readAsStringSync();
    world = CollisionWorld.fromJson(jsonDecode(json) as Map<String, dynamic>);
  });

  test('terrain matches spawn heights reported by the imported scene', () {
    // Engine-space positions of the Spawn0 / Spawn1 nodes as loaded by
    // flutter_scene (glTF z negated). Spawns sit exactly on the terrain.
    expect(world.terrainHeight(10, 5), closeTo(4.0, 0.01));
    expect(world.terrainHeight(-60, -30), closeTo(5.338, 0.01));
  });

  test('floors inside buildings are walkable', () {
    // House_A: glTF (-2, z 5) -> engine (-2, z -5).
    final terrain = world.terrainHeight(-2, -5);
    final ground = world.groundHeight(-2, -5, terrain);
    expect(ground, greaterThan(terrain));
    expect(ground - terrain, lessThan(CollisionWorld.stepHeight));
  });

  BoxCollider tallWall() => world.boxes.firstWhere(
    (b) => b.halfExtents.y > 1.2 && b.halfExtents.x > 2 && b.halfExtents.z < 0.2,
  );

  test('walls block movement', () {
    final wall = tallWall();
    final feet = wall.bottom;
    // Start 1 m in front of the wall's face, walk 2 m straight through it.
    final out = wall.halfExtents.z + 1;
    final from = vm.Vector2(
      wall.center.x + wall.worldX(0, out),
      wall.center.z + wall.worldZ(0, out),
    );
    final to = vm.Vector2(
      wall.center.x + wall.worldX(0, out - 2),
      wall.center.z + wall.worldZ(0, out - 2),
    );
    final result = world.resolveMove(from, to, feet, 0.35, 1.8);
    final lz = wall.localZ(result.x - wall.center.x, result.y - wall.center.z);
    expect(lz, greaterThanOrEqualTo(wall.halfExtents.z + 0.35 - 1e-6));
  });

  test('rays hit walls and terrain', () {
    final wall = tallWall();
    final out = wall.halfExtents.z + 5;
    final origin = vm.Vector3(
      wall.center.x + wall.worldX(0, out),
      wall.center.y,
      wall.center.z + wall.worldZ(0, out),
    );
    final dir = (wall.center - origin)..normalize();
    final hit = world.raycast(origin, dir, 50)!;
    expect(hit.distance, closeTo(5, 0.01));

    final down = world.raycast(vm.Vector3(30, 50, 40), vm.Vector3(0, -1, 0), 100)!;
    expect(down.point.y, closeTo(world.terrainHeight(30, 40), 0.01));
  });
}
