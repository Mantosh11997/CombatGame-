import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart' as vm;

/// An oriented box collider (rotated about Y only), in engine coordinates.
class BoxCollider {
  BoxCollider(this.center, this.halfExtents, this.yaw)
    : _cos = math.cos(yaw),
      _sin = math.sin(yaw);

  final vm.Vector3 center;
  final vm.Vector3 halfExtents;
  final double yaw;
  final double _cos;
  final double _sin;

  double get top => center.y + halfExtents.y;
  double get bottom => center.y - halfExtents.y;

  /// World XZ offset from the center -> box-local XZ (inverse of rotationY).
  double localX(double dx, double dz) => _cos * dx - _sin * dz;
  double localZ(double dx, double dz) => _sin * dx + _cos * dz;

  /// Box-local XZ -> world XZ offset (rotationY).
  double worldX(double lx, double lz) => _cos * lx + _sin * lz;
  double worldZ(double lx, double lz) => -_sin * lx + _cos * lz;

  bool containsXZ(double x, double z, [double margin = 0]) {
    final dx = x - center.x, dz = z - center.z;
    return localX(dx, dz).abs() <= halfExtents.x + margin &&
        localZ(dx, dz).abs() <= halfExtents.z + margin;
  }
}

/// A vertical cylinder collider (tree trunk, rock), in engine coordinates.
class CircleCollider {
  CircleCollider(this.x, this.z, this.radius);
  final double x;
  final double z;
  final double radius;
}

class RayHit {
  RayHit(this.distance, this.point, this.normal);
  final double distance;
  final vm.Vector3 point;
  final vm.Vector3 normal;
}

/// Gameplay collision for the map, built from the exporter's
/// `*.collision.json` (terrain heightfield + box and circle colliders).
///
/// The JSON is in glTF coordinates. flutter_scene imports glTF with Z
/// negated, so every Z (and every yaw) is negated here to match the rendered
/// scene.
class CollisionWorld {
  CollisionWorld({
    required this.size,
    required this.seaLevel,
    required int segments,
    required this.heights,
    required this.boxes,
    required this.circles,
  }) : _segments = segments,
       _cell = size / segments;

  factory CollisionWorld.fromJson(Map<String, dynamic> json) {
    final hf = json['heightfield'] as Map<String, dynamic>;
    final heights = Float32List.fromList([
      for (final h in hf['heights'] as List) (h as num).toDouble(),
    ]);
    final boxes = <BoxCollider>[];
    for (final b in json['boxes'] as List) {
      final c = (b['c'] as List).cast<num>();
      final h = (b['h'] as List).cast<num>();
      boxes.add(
        BoxCollider(
          vm.Vector3(c[0].toDouble(), c[1].toDouble(), -c[2].toDouble()),
          vm.Vector3(h[0].toDouble(), h[1].toDouble(), h[2].toDouble()),
          -(b['yaw'] as num).toDouble(),
        ),
      );
    }
    final circles = [
      for (final c in (json['circles'] as List))
        CircleCollider(
          (c[0] as num).toDouble(),
          -(c[1] as num).toDouble(),
          (c[2] as num).toDouble(),
        ),
    ];
    return CollisionWorld(
      size: (json['size'] as num).toDouble(),
      seaLevel: (json['seaLevel'] as num).toDouble(),
      segments: hf['segments'] as int,
      heights: heights,
      boxes: boxes,
      circles: circles,
    );
  }

  final double size;
  final double seaLevel;
  final List<BoxCollider> boxes;
  final List<CircleCollider> circles;
  final int _segments;
  /// Terrain vertex heights, row-major from glTF (-size/2, -size/2).
  final Float32List heights;
  final double _cell;

  /// Highest ledge the player can step onto without jumping (stairs, curbs).
  static const double stepHeight = 0.45;

  /// Water deeper than this below sea level blocks walking.
  static const double maxWadeDepth = 0.8;

  double _h(int ix, int iz) => heights[iz * (_segments + 1) + ix];

  /// Terrain height at engine-space (x, z), matching the rendered mesh's
  /// triangulation exactly.
  double terrainHeight(double x, double z) {
    // The heightfield rows run along glTF z, which is engine -z.
    final fx = (x + size / 2) / _cell;
    final fz = (-z + size / 2) / _cell;
    if (fx < 0 || fz < 0 || fx > _segments || fz > _segments) {
      return seaLevel - 3;
    }
    final ix = math.min(fx.floor(), _segments - 1);
    final iz = math.min(fz.floor(), _segments - 1);
    final u = fx - ix, v = fz - iz;
    final a = _h(ix, iz), b = _h(ix, iz + 1);
    final c = _h(ix + 1, iz + 1), d = _h(ix + 1, iz);
    // Triangles (a, b, d) and (b, c, d), split along the b-d diagonal.
    if (u + v <= 1) return a + (d - a) * u + (b - a) * v;
    return c + (b - c) * (1 - u) + (d - c) * (1 - v);
  }

  /// Height of whatever the player would stand on at (x, z): terrain, or the
  /// top of a floor/stair/crate no higher than [feetY] + [stepHeight].
  double groundHeight(double x, double z, double feetY) {
    var ground = terrainHeight(x, z);
    final reach = feetY + stepHeight;
    for (final b in boxes) {
      final top = b.top;
      if (top > ground && top <= reach && b.containsXZ(x, z)) ground = top;
    }
    return ground;
  }

  /// Moves a standing cylinder (feet at [feetY], [radius], [height]) from
  /// [from] toward [to] (XZ), pushing it out of walls and trees. A move into
  /// deep water is refused. Returns the corrected XZ position.
  vm.Vector2 resolveMove(
    vm.Vector2 from,
    vm.Vector2 to,
    double feetY,
    double radius,
    double height,
  ) {
    // Sub-step long moves (lag spikes) so thin walls cannot be skipped.
    final steps = math.max(1, ((to - from).length / (radius * 0.5)).ceil());
    var px = from.x, pz = from.y;
    final sx = (to.x - from.x) / steps, sz = (to.y - from.y) / steps;
    for (var step = 0; step < steps; step++) {
      px += sx;
      pz += sz;
      (px, pz) = _pushOut(px, pz, feetY, radius, height);
    }
    if (terrainHeight(px, pz) < seaLevel - maxWadeDepth) {
      return from.clone(); // deep water or off the island
    }
    return vm.Vector2(px, pz);
  }

  (double, double) _pushOut(
    double px,
    double pz,
    double feetY,
    double radius,
    double height,
  ) {
    final lo = feetY + stepHeight, hi = feetY + height;
    for (var iteration = 0; iteration < 3; iteration++) {
      for (final b in boxes) {
        if (b.top <= lo || b.bottom >= hi) continue;
        final dx = px - b.center.x, dz = pz - b.center.z;
        final lx = b.localX(dx, dz), lz = b.localZ(dx, dz);
        final ex = b.halfExtents.x, ez = b.halfExtents.z;
        if (lx.abs() > ex + radius || lz.abs() > ez + radius) continue;
        final cx = lx.clamp(-ex, ex), cz = lz.clamp(-ez, ez);
        var ox = lx - cx, oz = lz - cz;
        final dist = math.sqrt(ox * ox + oz * oz);
        double nx, nz;
        if (dist > 1e-6) {
          if (dist >= radius) continue;
          final push = radius - dist;
          nx = ox / dist * push;
          nz = oz / dist * push;
        } else {
          // Center is inside the box: leave along the shallowest axis.
          final penX = ex - lx.abs() + radius, penZ = ez - lz.abs() + radius;
          if (penX < penZ) {
            nx = lx >= 0 ? penX : -penX;
            nz = 0;
          } else {
            nx = 0;
            nz = lz >= 0 ? penZ : -penZ;
          }
        }
        px += b.worldX(nx, nz);
        pz += b.worldZ(nx, nz);
      }
      for (final c in circles) {
        final dx = px - c.x, dz = pz - c.z;
        final min = c.radius + radius;
        final d2 = dx * dx + dz * dz;
        if (d2 >= min * min || d2 < 1e-9) continue;
        final d = math.sqrt(d2);
        px = c.x + dx / d * min;
        pz = c.z + dz / d * min;
      }
    }
    return (px, pz);
  }

  /// Closest hit along a ray against terrain, boxes and trunks.
  RayHit? raycast(vm.Vector3 origin, vm.Vector3 dir, double maxDistance) {
    var best = maxDistance;
    vm.Vector3? bestNormal;

    for (final b in boxes) {
      final hit = _rayBox(origin, dir, b, best);
      if (hit != null) {
        best = hit.$1;
        bestNormal = hit.$2;
      }
    }
    for (final c in circles) {
      final t = _rayCylinder(origin, dir, c, best);
      if (t != null) {
        best = t;
        final p = origin + dir * t;
        bestNormal = vm.Vector3(p.x - c.x, 0, p.z - c.z)..normalize();
      }
    }
    final tTerrain = _rayTerrain(origin, dir, best);
    if (tTerrain != null) {
      best = tTerrain;
      final p = origin + dir * tTerrain;
      const e = 0.25;
      bestNormal = vm.Vector3(
        terrainHeight(p.x - e, p.z) - terrainHeight(p.x + e, p.z),
        2 * e,
        terrainHeight(p.x, p.z - e) - terrainHeight(p.x, p.z + e),
      )..normalize();
    }
    if (bestNormal == null) return null;
    return RayHit(best, origin + dir * best, bestNormal);
  }

  (double, vm.Vector3)? _rayBox(
    vm.Vector3 o,
    vm.Vector3 d,
    BoxCollider b,
    double maxT,
  ) {
    // Into box-local space (rotation about Y only).
    final ox = o.x - b.center.x, oz = o.z - b.center.z;
    final lo = [b.localX(ox, oz), o.y - b.center.y, b.localZ(ox, oz)];
    final ld = [b.localX(d.x, d.z), d.y, b.localZ(d.x, d.z)];
    final ext = [b.halfExtents.x, b.halfExtents.y, b.halfExtents.z];
    var tMin = 0.0, tMax = maxT;
    var axis = -1;
    var sign = 0.0;
    for (var i = 0; i < 3; i++) {
      if (ld[i].abs() < 1e-9) {
        if (lo[i].abs() > ext[i]) return null;
        continue;
      }
      var t1 = (-ext[i] - lo[i]) / ld[i];
      var t2 = (ext[i] - lo[i]) / ld[i];
      var s = -1.0;
      if (t1 > t2) {
        final tmp = t1;
        t1 = t2;
        t2 = tmp;
        s = 1.0;
      }
      if (t1 > tMin) {
        tMin = t1;
        axis = i;
        sign = s;
      }
      if (t2 < tMax) tMax = t2;
      if (tMin > tMax) return null;
    }
    if (axis < 0) return null; // origin inside the box
    final n = [0.0, 0.0, 0.0]..[axis] = sign;
    final normal = vm.Vector3(b.worldX(n[0], n[2]), n[1], b.worldZ(n[0], n[2]));
    return (tMin, normal);
  }

  double? _rayCylinder(vm.Vector3 o, vm.Vector3 d, CircleCollider c, double maxT) {
    final ox = o.x - c.x, oz = o.z - c.z;
    final a = d.x * d.x + d.z * d.z;
    if (a < 1e-9) return null;
    final b = 2 * (ox * d.x + oz * d.z);
    final cc = ox * ox + oz * oz - c.radius * c.radius;
    final disc = b * b - 4 * a * cc;
    if (disc < 0) return null;
    final t = (-b - math.sqrt(disc)) / (2 * a);
    if (t <= 0 || t >= maxT) return null;
    // Trunks are ~4 m tall above the ground at their base.
    final y = o.y + d.y * t;
    final base = terrainHeight(c.x, c.z);
    if (y < base || y > base + 4) return null;
    return t;
  }

  double? _rayTerrain(vm.Vector3 o, vm.Vector3 d, double maxT) {
    const step = 0.5;
    var prevT = 0.0;
    var prevAbove = o.y - terrainHeight(o.x, o.z);
    if (prevAbove < 0) return null;
    for (var t = step; t <= maxT; t += step) {
      final p = o + d * t;
      final above = p.y - terrainHeight(p.x, p.z);
      if (above < 0) {
        // Refine between the last two samples.
        var lo = prevT, hi = t;
        for (var i = 0; i < 8; i++) {
          final mid = (lo + hi) / 2;
          final m = o + d * mid;
          if (m.y - terrainHeight(m.x, m.z) < 0) {
            hi = mid;
          } else {
            lo = mid;
          }
        }
        return hi;
      }
      prevT = t;
      prevAbove = above;
    }
    return null;
  }
}
