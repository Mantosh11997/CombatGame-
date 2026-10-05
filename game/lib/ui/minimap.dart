import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../game/battle_royale.dart';
import '../game/character_controller.dart';
import '../game/game.dart';

/// Island map with the safe zone, the next zone, the plane's path and the
/// player's position and heading.
class Minimap extends StatelessWidget {
  const Minimap({super.key, required this.game, this.size = 132});
  final Game game;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      border: Border.all(color: Colors.white70, width: 2),
      borderRadius: BorderRadius.circular(4),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: CustomPaint(painter: _MinimapPainter(game)),
    ),
  );
}

class _MinimapPainter extends CustomPainter {
  _MinimapPainter(this.game) : super(repaint: game.frame);
  final Game game;

  @override
  void paint(Canvas canvas, Size size) {
    final image = game.minimap;
    if (image != null) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    Offset at(double x, double z) => Offset(game.mapX(x) * size.width, game.mapY(z) * size.height);
    double scale(double meters) => meters / game.world.size * size.width;

    final br = game.br;
    if (br != null) {
      if (br.phase == MatchPhase.plane) {
        final start = br.planePosition;
        final dir = br.planeVelocity.normalized();
        final a = at(start.x - dir.x * 400, start.z - dir.z * 400);
        final b = at(start.x + dir.x * 400, start.z + dir.z * 400);
        canvas.drawLine(a, b, Paint()..color = Colors.white54..strokeWidth = 1.5);
        canvas.drawCircle(at(start.x, start.z), 4, Paint()..color = Colors.white);
      }
      final zone = br.zone;
      // Darken outside the safe zone.
      final outside = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addOval(Rect.fromCircle(center: at(zone.center.x, zone.center.y), radius: scale(zone.radius)));
      canvas.drawPath(outside, Paint()..color = const Color(0x553A6BFF));
      canvas.drawCircle(
        at(zone.center.x, zone.center.y),
        scale(zone.radius),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = const Color(0xFF5AA0FF)
          ..strokeWidth = 1.5,
      );
      if (br.phase == MatchPhase.battle && !zone.finished) {
        canvas.drawCircle(
          at(zone.nextCenter.x, zone.nextCenter.y),
          scale(zone.nextRadius),
          Paint()
            ..style = PaintingStyle.stroke
            ..color = Colors.white
            ..strokeWidth = 1.2,
        );
      }
    }

    // The player, as an arrow pointing the way the camera looks.
    final c = game.player.controller;
    final p = c.mode == MoveMode.plane && br != null ? br.planePosition : c.position;
    canvas.save();
    canvas.translate(at(p.x, p.z).dx, at(p.x, p.z).dy);
    canvas.rotate(game.cameraYaw);
    final arrow = Path()
      ..moveTo(0, -6)
      ..lineTo(4.5, 5)
      ..lineTo(0, 2.5)
      ..lineTo(-4.5, 5)
      ..close();
    canvas.drawPath(arrow, Paint()..color = const Color(0xFFFFD54A));
    canvas.drawPath(arrow, Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.black87
      ..strokeWidth = 1);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter old) => false;
}

/// "m:ss" for a countdown.
String formatSeconds(double seconds) {
  final s = math.max(0, seconds.ceil());
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
