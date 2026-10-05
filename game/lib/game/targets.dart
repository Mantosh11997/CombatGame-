import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Practice dummies on a post. They take damage, flash when hit, fall over
/// when their health runs out and stand back up a few seconds later.
class TargetDummy {
  TargetDummy._(this.root, this._parts, this._normal, this._flash, this.base);

  static const double maxHealth = 100;
  static const double _respawnDelay = 3;

  /// Build the shared geometry/materials once and create dummies from them.
  static TargetDummyFactory factory() => TargetDummyFactory();

  final Node root;
  final List<Node> _parts;
  final List<Mesh> _normal;
  final List<Mesh> _flash;

  /// Ground point under the post.
  final vm.Vector3 base;
  double health = maxHealth;
  double _flashLeft = 0;
  double _downTime = 0;
  double _fall = 0;

  bool get isDown => health <= 0;

  /// Hit test. Returns the distance along the ray and whether it was the head.
  (double, bool)? raycast(vm.Vector3 origin, vm.Vector3 dir, double maxT) {
    if (isDown) return null;
    double? best;
    var head = false;
    // Head: sphere.
    final hc = base + vm.Vector3(0, 1.72, 0);
    final th = _raySphere(origin, dir, hc, 0.16);
    if (th != null && th < maxT) {
      best = th;
      head = true;
    }
    // Body: vertical cylinder from hips to shoulders.
    final tb = _rayCylinder(origin, dir, base, 0.3, 0.75, 1.58);
    if (tb != null && tb < (best ?? maxT)) {
      best = tb;
      head = false;
    }
    return best == null ? null : (best, head);
  }

  /// Applies damage; returns true when this hit knocked the dummy down.
  bool damage(double amount) {
    if (isDown) return false;
    health -= amount;
    _flashLeft = 0.12;
    _setFlash(true);
    if (health <= 0) {
      _downTime = _respawnDelay;
      return true;
    }
    return false;
  }

  void update(double dt) {
    if (_flashLeft > 0) {
      _flashLeft -= dt;
      if (_flashLeft <= 0) _setFlash(false);
    }
    if (isDown) {
      _downTime -= dt;
      _fall = math.min(1, _fall + dt * 4);
      if (_downTime <= 0) health = maxHealth;
    } else if (_fall > 0) {
      _fall = math.max(0, _fall - dt * 2);
    }
    // Tip backwards around the base of the post.
    root.rotation = vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), -_fall * math.pi / 2 * 0.95);
  }

  void _setFlash(bool on) {
    for (var i = 0; i < _parts.length; i++) {
      _parts[i].mesh = on ? _flash[i] : _normal[i];
    }
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

class TargetDummyFactory {
  TargetDummyFactory()
    : _materials = [
        PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(0.45, 0.32, 0.2, 1)
          ..roughnessFactor = 0.9
          ..metallicFactor = 0,
        PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(0.85, 0.42, 0.12, 1)
          ..roughnessFactor = 0.7
          ..metallicFactor = 0,
        PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(0.92, 0.9, 0.85, 1)
          ..roughnessFactor = 0.7
          ..metallicFactor = 0,
      ],
      _flashMaterial = PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(1, 0.1, 0.05, 1)
        ..emissiveFactor = vm.Vector4(1, 0.1, 0.05, 1)
        ..metallicFactor = 0;

  final List<PhysicallyBasedMaterial> _materials;
  final PhysicallyBasedMaterial _flashMaterial;
  final _post = CylinderGeometry(bottomRadius: 0.05, topRadius: 0.05, height: 0.8, radialSegments: 10);
  final _stand = CylinderGeometry(bottomRadius: 0.35, topRadius: 0.3, height: 0.08, radialSegments: 16);
  final _body = CapsuleGeometry(radius: 0.26, height: 0.4, radialSegments: 20, capRings: 6);
  final _head = SphereGeometry(radius: 0.15, segments: 20, rings: 12);
  final _ring = TorusGeometry(radius: 0.18, tubeRadius: 0.03, radialSegments: 24, tubularSegments: 8);

  TargetDummy create(vm.Vector3 base, double yaw) {
    final root = Node()..position = base;
    final holder = Node()..rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), yaw);
    root.add(holder);
    final parts = <Node>[];
    final normal = <Mesh>[];
    final flash = <Mesh>[];
    void part(Geometry g, int material, vm.Vector3 at, [vm.Quaternion? rotation]) {
      final mesh = Mesh(g, _materials[material]);
      final node = Node(mesh: mesh)..position = at;
      if (rotation != null) node.rotation = rotation;
      holder.add(node);
      parts.add(node);
      normal.add(mesh);
      flash.add(Mesh(g, _flashMaterial));
    }

    part(_stand, 0, vm.Vector3(0, 0.04, 0));
    part(_post, 0, vm.Vector3(0, 0.4, 0));
    part(_body, 1, vm.Vector3(0, 1.17, 0));
    part(_head, 2, vm.Vector3(0, 1.72, 0));
    // Bullseye ring on the chest, facing the dummy's front (+Z).
    part(_ring, 2, vm.Vector3(0, 1.25, 0.25), vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), math.pi / 2));
    return TargetDummy._(root, parts, normal, flash, base.clone());
  }
}
