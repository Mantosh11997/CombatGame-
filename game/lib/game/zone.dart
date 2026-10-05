import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;

/// One step of the shrinking safe zone: wait, then shrink to [radius] over
/// [shrinkSeconds]. Standing outside costs [damagePerSecond].
class ZonePhase {
  const ZonePhase(this.waitSeconds, this.shrinkSeconds, this.radius, this.damagePerSecond);
  final double waitSeconds;
  final double shrinkSeconds;
  final double radius;
  final double damagePerSecond;
}

/// The battle royale safe zone. Pure logic: the game reads [center]/[radius]
/// to draw it and [damagePerSecond] to hurt players outside.
class SafeZone {
  SafeZone({
    required vm.Vector2 center,
    required double radius,
    required this.phases,
    required this.random,
    this.isGoodCenter,
  }) : _from = center.clone(),
       _fromRadius = radius,
       center = center.clone(),
       radius = radius {
    _pickNext();
  }

  static const defaultPhases = [
    ZonePhase(40, 30, 85, 2),
    ZonePhase(30, 25, 50, 4),
    ZonePhase(25, 20, 26, 7),
    ZonePhase(20, 15, 10, 10),
    ZonePhase(15, 15, 0, 15),
  ];

  final List<ZonePhase> phases;
  final math.Random random;

  /// Optional filter for the next circle's center (e.g. "on land").
  final bool Function(vm.Vector2 point)? isGoodCenter;

  /// Current circle.
  vm.Vector2 center;
  double radius;

  /// Where the circle is heading in the current phase.
  late vm.Vector2 nextCenter;
  late double nextRadius;

  vm.Vector2 _from;
  double _fromRadius;
  int phase = 0;
  double _time = 0;

  bool get finished => phase >= phases.length;
  bool get shrinking => !finished && _time >= phases[phase].waitSeconds;

  /// Seconds until the current wait or shrink ends.
  double get secondsLeft {
    if (finished) return 0;
    final p = phases[phase];
    return shrinking ? p.waitSeconds + p.shrinkSeconds - _time : p.waitSeconds - _time;
  }

  double get damagePerSecond => phases[math.min(phase, phases.length - 1)].damagePerSecond;

  bool contains(double x, double z) {
    final dx = x - center.x, dz = z - center.y;
    return dx * dx + dz * dz <= radius * radius;
  }

  /// Distance outside the circle (0 when inside).
  double outsideBy(double x, double z) =>
      math.max(0, math.sqrt((x - center.x) * (x - center.x) + (z - center.y) * (z - center.y)) - radius);

  void _pickNext() {
    if (finished) return;
    final target = phases[phase].radius;
    final maxOffset = math.max(0.0, _fromRadius - target);
    vm.Vector2 candidate = _from.clone();
    for (var attempt = 0; attempt < 20; attempt++) {
      final a = random.nextDouble() * math.pi * 2;
      final r = math.sqrt(random.nextDouble()) * maxOffset;
      candidate = _from + vm.Vector2(math.cos(a), math.sin(a)) * r;
      if (isGoodCenter?.call(candidate) ?? true) break;
    }
    nextCenter = candidate;
    nextRadius = target;
  }

  void update(double dt) {
    if (finished) return;
    _time += dt;
    final p = phases[phase];
    if (_time >= p.waitSeconds) {
      final t = ((_time - p.waitSeconds) / p.shrinkSeconds).clamp(0.0, 1.0);
      center = _from + (nextCenter - _from) * t;
      radius = _fromRadius + (nextRadius - _fromRadius) * t;
      if (t >= 1) {
        _from = nextCenter.clone();
        _fromRadius = nextRadius;
        phase++;
        _time = 0;
        _pickNext();
      }
    }
  }
}
