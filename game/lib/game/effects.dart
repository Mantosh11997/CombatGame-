import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Short-lived combat visuals: bullet tracers, muzzle flash and impact puffs.
/// Every node is created once and reused, so firing allocates nothing on the
/// GPU side.
class Effects {
  Effects(Scene scene) {
    final tracerMaterial = UnlitMaterial()..baseColorFactor = vm.Vector4(1, 0.85, 0.45, 1);
    final tracerGeometry = CylinderGeometry(bottomRadius: 0.012, topRadius: 0.012, height: 1, radialSegments: 6, bottomCap: false, topCap: false);
    for (var i = 0; i < 24; i++) {
      final node = Node(mesh: Mesh(tracerGeometry, tracerMaterial))
        ..visible = false
        ..castsShadows = false;
      scene.add(node);
      _tracers.add(_Fx(node));
    }

    final dust = UnlitMaterial()..baseColorFactor = vm.Vector4(0.75, 0.68, 0.55, 1);
    final blood = UnlitMaterial()..baseColorFactor = vm.Vector4(0.85, 0.12, 0.08, 1);
    final puff = IcosphereGeometry(radius: 0.08, subdivisions: 1);
    for (var i = 0; i < 24; i++) {
      final node = Node(mesh: Mesh(puff, dust))
        ..visible = false
        ..castsShadows = false;
      final hitNode = Node(mesh: Mesh(puff, blood))
        ..visible = false
        ..castsShadows = false;
      scene.add(node);
      scene.add(hitNode);
      _impacts.add(_Fx(node));
      _hits.add(_Fx(hitNode));
    }

    final flashMaterial = UnlitMaterial()..baseColorFactor = vm.Vector4(1, 0.9, 0.5, 1);
    _flash = Node(mesh: Mesh(IcosphereGeometry(radius: 0.07, subdivisions: 1), flashMaterial))
      ..visible = false
      ..castsShadows = false;
    scene.add(_flash);
  }

  final _tracers = <_Fx>[];
  final _impacts = <_Fx>[];
  final _hits = <_Fx>[];
  late final Node _flash;
  double _flashLeft = 0;
  int _nextTracer = 0, _nextImpact = 0, _nextHit = 0;
  final _random = math.Random();

  void tracer(vm.Vector3 from, vm.Vector3 to) {
    final dir = to - from;
    final length = dir.length;
    if (length < 0.05) return;
    final fx = _tracers[_nextTracer++ % _tracers.length];
    // Unit-height cylinder along Y, stretched to the shot and aligned to it.
    fx.node.localTransform = vm.Matrix4.compose(
      from + dir * 0.5,
      vm.Quaternion.fromTwoVectors(vm.Vector3(0, 1, 0), dir.normalized()),
      vm.Vector3(1, length, 1),
    );
    fx.node.visible = true;
    fx.life = 0.05;
  }

  void impact(vm.Vector3 at, {bool flesh = false}) {
    final pool = flesh ? _hits : _impacts;
    final fx = pool[(flesh ? _nextHit++ : _nextImpact++) % pool.length];
    fx.base = at.clone();
    fx.node.position = at;
    fx.node.scale = vm.Vector3.all(1);
    fx.node.visible = true;
    fx.life = fx.duration = 0.25;
  }

  void muzzleFlash(vm.Vector3 at) {
    _flash.position = at;
    _flash.scale = vm.Vector3.all(0.7 + _random.nextDouble() * 0.7);
    _flash.visible = true;
    _flashLeft = 0.045;
  }

  void update(double dt) {
    for (final fx in _tracers) {
      if (!fx.node.visible) continue;
      fx.life -= dt;
      if (fx.life <= 0) fx.node.visible = false;
    }
    for (final fx in [..._impacts, ..._hits]) {
      if (!fx.node.visible) continue;
      fx.life -= dt;
      if (fx.life <= 0) {
        fx.node.visible = false;
        continue;
      }
      // Puff grows, rises a little and shrinks away.
      final t = 1 - fx.life / fx.duration;
      fx.node.scale = vm.Vector3.all(math.max(0.01, math.sin(t * math.pi) * 1.4));
      fx.node.position = fx.base! + vm.Vector3(0, t * 0.15, 0);
    }
    if (_flashLeft > 0) {
      _flashLeft -= dt;
      if (_flashLeft <= 0) _flash.visible = false;
    }
  }
}

class _Fx {
  _Fx(this.node);
  final Node node;
  double life = 0;
  double duration = 1;
  vm.Vector3? base;
}
