import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'collision_world.dart';

/// Third-person movement for the soldier: camera-relative walking and
/// sprinting, gravity and jumping, collision against the map, and animation
/// blending between the exported clips.
///
/// [node] is the player root, placed at the feet and yawed so that local +Z
/// is the facing direction. The game calls [update] itself each frame, before
/// positioning the camera, so the camera never trails the player by a frame.
class PlayerController {
  PlayerController(this.node, this.world, this.soldier, vm.Vector3 spawn) : position = spawn.clone() {
    for (final animation in soldier.parsedAnimations) {
      final clip = soldier.createAnimationClip(animation)
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
  final Node soldier;

  static const double radius = 0.35;
  static const double height = 1.8;
  static const double walkSpeed = 3.2;
  static const double runSpeed = 6.2;
  static const double jumpVelocity = 5.2;
  static const double gravity = 16;

  // Inputs, written by the game each frame.
  /// Stick input: x = right, y = forward, length up to 1.
  vm.Vector2 moveInput = vm.Vector2.zero();
  bool sprint = false;

  /// Camera heading (radians); movement is relative to it.
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

  final Map<String, AnimationClip> _clips = {};
  String _current = 'Idle';

  void jump() => _jumpQueued = true;

  /// Unit vector the camera looks along, flattened.
  static vm.Vector3 headingForward(double yaw) =>
      vm.Vector3(math.sin(yaw), 0, math.cos(yaw));

  /// Screen-right for a camera with this heading.
  static vm.Vector3 headingRight(double yaw) =>
      vm.Vector3(math.cos(yaw), 0, -math.sin(yaw));

  double get horizontalSpeed => math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z);

  void update(double deltaSeconds) {
    // Clamp long frames (tab switch, hitch) so physics stays stable.
    final dt = math.min(deltaSeconds, 1 / 20);
    if (dt <= 0) return;
    _move(dt);
    _animate(dt);
    _applyTransform();
  }

  void _move(double dt) {
    // Desired horizontal velocity from the stick, relative to the camera.
    final input = moveInput.length > 1 ? moveInput.normalized() : moveInput;
    final speed = sprint && input.length > 0.5 ? runSpeed : walkSpeed;
    final desired = (headingRight(cameraYaw) * input.x + headingForward(cameraYaw) * input.y) * speed;
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
    final speed = horizontalSpeed;
    final String base;
    if (speed > 4.2) {
      base = 'Run';
    } else if (speed > 0.3) {
      base = 'Walk';
    } else {
      base = armed ? 'Aim' : 'Idle';
    }
    final target = armed && base != 'Aim' ? '${base}Aim' : base;
    if (_clips.containsKey(target)) _current = target;

    // Match the stride to the actual speed so feet don't slide.
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
