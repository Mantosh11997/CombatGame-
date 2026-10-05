import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'collision_world.dart';

enum MoveMode { plane, freefall, parachute, ground, dead }

/// Movement and animation for one soldier, used identically by the player
/// and the AI: riding the plane, freefall, parachute, walking/running with
/// collision, and falling over when killed.
///
/// [node] is the character root, placed at the feet and yawed so local +Z is
/// the facing direction. The owner calls [update] once per frame.
class CharacterController {
  CharacterController({
    required this.node,
    required this.world,
    required this.model,
    required vm.Vector3 spawn,
    this.parachute,
  }) : position = spawn.clone() {
    // The imported soldier faces -Z; the tilt pivot turns it to face +Z and
    // lets freefall/death rotate the body around the hips.
    _tilt = Node()..position = vm.Vector3(0, hipHeight, 0);
    model.position = vm.Vector3(0, -hipHeight, 0);
    _tilt.add(model);
    node.add(_tilt);
    if (parachute != null) {
      parachute!.visible = false;
      node.add(parachute!);
    }
    for (final animation in model.parsedAnimations) {
      final clip = model.createAnimationClip(animation)
        ..loop = true
        ..weight = animation.name == _current ? 1 : 0;
      if (animation.name == _current) clip.play();
      _clips[animation.name] = clip;
    }
    _applyTransform();
  }

  final Node node;
  final CollisionWorld world;

  /// The imported soldier model (owns the animation clips).
  final Node model;
  final Node? parachute;
  late final Node _tilt;

  static const double hipHeight = 0.98;
  static const double radius = 0.35;
  static const double height = 1.8;
  static const double walkSpeed = 3.2;
  static const double runSpeed = 6.2;
  static const double jumpVelocity = 5.2;
  static const double gravity = 16;
  static const double freefallSpeed = 28;
  static const double freefallGlide = 14;
  static const double parachuteSpeed = 5.5;
  static const double parachuteGlide = 7.5;

  /// Height above ground at which the parachute opens by itself.
  static const double autoOpenHeight = 38;

  /// The parachute can be opened by hand below this height above ground.
  static const double manualOpenHeight = 95;

  MoveMode mode = MoveMode.ground;

  // Inputs, written by the owner each frame.
  /// Stick input: x = right, y = forward (relative to [cameraYaw]), length up to 1.
  vm.Vector2 moveInput = vm.Vector2.zero();
  bool sprint = false;

  /// Heading the stick is relative to (camera for the player, 0 for bots).
  double cameraYaw = 0;

  /// When set, the soldier turns to face this heading (aiming/shooting).
  double? faceYaw;

  /// Whether a gun is equipped (selects the weapon-holding clips).
  bool armed = false;

  vm.Vector3 position;
  vm.Vector3 velocity = vm.Vector3.zero();
  double yaw = 0;
  bool grounded = true;
  bool _jumpQueued = false;
  double _tiltAngle = 0;
  double _deathTime = 0;

  final Map<String, AnimationClip> _clips = {};
  String _current = 'Idle';

  void jump() => _jumpQueued = true;

  /// Unit vector for a heading, flattened.
  static vm.Vector3 headingForward(double yaw) => vm.Vector3(math.sin(yaw), 0, math.cos(yaw));

  /// Screen-right for a camera with this heading.
  static vm.Vector3 headingRight(double yaw) => vm.Vector3(math.cos(yaw), 0, -math.sin(yaw));

  double get horizontalSpeed => math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z);

  double get heightAboveGround => position.y - world.terrainHeight(position.x, position.z);

  bool get canOpenParachute => mode == MoveMode.freefall && heightAboveGround < manualOpenHeight;

  /// Leaves the plane at [from] with the plane's [planeVelocity].
  void exitPlane(vm.Vector3 from, vm.Vector3 planeVelocity) {
    position = from.clone();
    velocity = planeVelocity * 0.4;
    mode = MoveMode.freefall;
    node.visible = true;
  }

  void openParachute() {
    if (mode != MoveMode.freefall) return;
    mode = MoveMode.parachute;
    parachute?.visible = true;
  }

  void die() {
    mode = MoveMode.dead;
    parachute?.visible = false;
    _deathTime = 0;
  }

  void update(double deltaSeconds) {
    // Clamp long frames (tab switch, hitch) so physics stays stable.
    final dt = math.min(deltaSeconds, 1 / 20);
    if (dt <= 0) return;
    switch (mode) {
      case MoveMode.plane:
        node.visible = false;
        return;
      case MoveMode.freefall:
      case MoveMode.parachute:
        _fly(dt);
      case MoveMode.ground:
        _walk(dt);
      case MoveMode.dead:
        _deathTime += dt;
    }
    _animate(dt);
    _applyTransform();
  }

  vm.Vector3 _desiredHorizontal(double speed) {
    final input = moveInput.length > 1 ? moveInput.normalized() : moveInput;
    return (headingRight(cameraYaw) * input.x + headingForward(cameraYaw) * input.y) * speed;
  }

  void _fly(double dt) {
    final parachuting = mode == MoveMode.parachute;
    final desired = _desiredHorizontal(parachuting ? parachuteGlide : freefallGlide);
    final t = 1 - math.exp(-(parachuting ? 2.0 : 1.5) * dt);
    velocity.x += (desired.x - velocity.x) * t;
    velocity.z += (desired.z - velocity.z) * t;
    final fallSpeed = parachuting ? parachuteSpeed : freefallSpeed;
    velocity.y += (-fallSpeed - velocity.y) * (1 - math.exp(-(parachuting ? 3.0 : 0.8) * dt));
    position += velocity * dt;

    // Drift back toward the island so nobody lands in the sea.
    if (world.terrainHeight(position.x, position.z) < world.seaLevel + 0.5) {
      final toCenter = vm.Vector3(-position.x, 0, -position.z)..normalize();
      position += toCenter * (parachuting ? 6.0 : 10.0) * dt;
    }

    final horizontal = vm.Vector2(velocity.x, velocity.z);
    if (horizontal.length > 1) {
      final targetYaw = math.atan2(velocity.x, velocity.z);
      var diff = targetYaw - yaw;
      diff = math.atan2(math.sin(diff), math.cos(diff));
      yaw += diff * (1 - math.exp(-4 * dt));
    }

    if (mode == MoveMode.freefall && heightAboveGround < autoOpenHeight) openParachute();

    final ground = world.groundHeight(position.x, position.z, position.y);
    if (position.y <= ground) {
      position.y = ground;
      velocity.setValues(velocity.x * 0.3, 0, velocity.z * 0.3);
      mode = MoveMode.ground;
      grounded = true;
      parachute?.visible = false;
      _settleOnLand();
    }
  }

  /// After landing in shallow water or inside a wall, step to solid ground.
  void _settleOnLand() {
    var guard = 0;
    while (world.terrainHeight(position.x, position.z) < world.seaLevel - CollisionWorld.maxWadeDepth && guard++ < 200) {
      final toCenter = vm.Vector2(-position.x, -position.z)..normalize();
      position.x += toCenter.x;
      position.z += toCenter.y;
    }
    final here = vm.Vector2(position.x, position.z);
    final settled = world.resolveMove(here, here, position.y, radius, height);
    position.x = settled.x;
    position.z = settled.y;
    position.y = world.groundHeight(position.x, position.z, position.y);
  }

  void _walk(double dt) {
    // Desired horizontal velocity from the stick, relative to the camera.
    final speed = sprint && moveInput.length > 0.5 ? runSpeed : walkSpeed;
    final desired = _desiredHorizontal(speed);
    final accel = grounded ? 14.0 : 3.0;
    final t = 1 - math.exp(-accel * dt);
    velocity.x += (desired.x - velocity.x) * t;
    velocity.z += (desired.z - velocity.z) * t;

    if (_jumpQueued && grounded) {
      velocity.y = jumpVelocity;
      grounded = false;
    }
    _jumpQueued = false;
    if (!grounded) velocity.y -= gravity * dt;

    final from = vm.Vector2(position.x, position.z);
    final to = vm.Vector2(position.x + velocity.x * dt, position.z + velocity.z * dt);
    final moved = world.resolveMove(from, to, position.y, radius, height);
    // Keep velocity consistent with what collision allowed (slide along walls).
    velocity.x = (moved.x - from.x) / dt;
    velocity.z = (moved.y - from.y) / dt;
    position.x = moved.x;
    position.z = moved.y;

    final newY = position.y + velocity.y * dt;
    final ground = world.groundHeight(position.x, position.z, math.max(position.y, newY));
    if (newY <= ground) {
      position.y = ground;
      velocity.y = 0;
      grounded = true;
    } else if (grounded && velocity.y <= 0 && position.y - ground < 0.5) {
      // Walking down a slope or stairs: stay glued to the ground.
      position.y = ground;
    } else {
      position.y = newY;
      grounded = false;
    }

    // Turn toward the aim heading, or toward the direction of travel.
    double? targetYaw = faceYaw;
    if (targetYaw == null && horizontalSpeed > 0.4) {
      targetYaw = math.atan2(velocity.x, velocity.z);
    }
    if (targetYaw != null) {
      var diff = targetYaw - yaw;
      diff = math.atan2(math.sin(diff), math.cos(diff));
      yaw += diff * (1 - math.exp(-(faceYaw != null ? 25.0 : 10.0) * dt));
    }
  }

  void _animate(double dt) {
    final String target;
    var tilt = 0.0;
    switch (mode) {
      case MoveMode.freefall:
        target = 'Skydive';
        // Dive head-first when pushing forward, belly-flat otherwise.
        tilt = moveInput.y > 0.3 ? 1.25 : 0.95;
      case MoveMode.parachute:
        target = 'Parachute';
      case MoveMode.dead:
        target = _current; // freeze in the last pose while falling over
      case _:
        final speed = horizontalSpeed;
        final String base;
        if (speed > 4.2) {
          base = 'Run';
        } else if (speed > 0.3) {
          base = 'Walk';
        } else {
          base = armed ? 'Aim' : 'Idle';
        }
        target = armed && base != 'Aim' ? '${base}Aim' : base;
    }
    if (_clips.containsKey(target)) _current = target;

    if (mode == MoveMode.dead) {
      // Topple backwards and come to rest on the ground.
      final p = math.min(1.0, _deathTime / 0.45);
      _tilt.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), math.pi) *
          vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), p * math.pi / 2);
      _tilt.position = vm.Vector3(0, hipHeight - 0.8 * p, -0.1 * p);
      for (final clip in _clips.values) {
        if (clip.playing) clip.pause();
      }
      return;
    }

    _tiltAngle += (tilt - _tiltAngle) * (1 - math.exp(-5 * dt));
    _tilt.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), math.pi) *
        vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), -_tiltAngle);

    // Cross-fade weights and match the stride to the actual speed.
    final speed = horizontalSpeed;
    for (final entry in _clips.entries) {
      final clip = entry.value;
      final active = entry.key == _current;
      final goal = active ? 1.0 : 0.0;
      clip.weight += (goal - clip.weight) * (1 - math.exp(-10 * dt));
      if (active && !clip.playing) clip.play();
      if (!active && clip.weight < 0.01 && clip.playing) {
        clip.weight = 0;
        clip.pause();
      }
      if (entry.key.startsWith('Walk')) clip.playbackTimeScale = (speed / 1.6).clamp(0.6, 1.6);
      if (entry.key.startsWith('Run')) clip.playbackTimeScale = (speed / 5.5).clamp(0.8, 1.3);
    }
  }

  void _applyTransform() {
    node.position = position;
    node.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), yaw);
  }
}
