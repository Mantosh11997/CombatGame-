import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/kit.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../game/battle_royale.dart';
import '../game/character_controller.dart';
import '../game/combatant.dart';
import '../game/game.dart';
import 'minimap.dart';

/// Touch controls and readouts drawn over the 3D view. On a keyboard:
/// WASD move, Shift sprint, Space jump / parachute, R reload, 1-5 guns,
/// F fire, Q aim, H medkit, E pick up; drag on the right half to look.
class Hud extends StatefulWidget {
  const Hud({super.key, required this.game, required this.onExit, required this.onRestart});
  final Game game;
  final VoidCallback onExit;
  final VoidCallback onRestart;

  @override
  State<Hud> createState() => _HudState();
}

class _HudState extends State<Hud> {
  Game get game => widget.game;
  GameInput get input => game.input;
  final _keys = <LogicalKeyboardKey>{};
  vm.Vector2 _stick = vm.Vector2.zero();
  final _focus = FocusNode();
  int _fireTouches = 0;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _syncMove() {
    double x = _stick.x, y = -_stick.y; // joystick up is screen -Y
    if (_keys.contains(LogicalKeyboardKey.keyW)) y += 1;
    if (_keys.contains(LogicalKeyboardKey.keyS)) y -= 1;
    if (_keys.contains(LogicalKeyboardKey.keyD)) x += 1;
    if (_keys.contains(LogicalKeyboardKey.keyA)) x -= 1;
    input.move = vm.Vector2(x, y);
    input.sprint = _keys.contains(LogicalKeyboardKey.shiftLeft) || _keys.contains(LogicalKeyboardKey.shiftRight);
    input.fire = _fireTouches > 0 || _keys.contains(LogicalKeyboardKey.keyF);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyDownEvent) {
      _keys.add(key);
      if (key == LogicalKeyboardKey.space) input.jump = true;
      if (key == LogicalKeyboardKey.keyR) input.reload = true;
      if (key == LogicalKeyboardKey.keyH) input.heal = true;
      if (key == LogicalKeyboardKey.keyE) input.pickup = true;
      if (key == LogicalKeyboardKey.keyQ) input.aim = !input.aim;
      const digits = [
        LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5,
      ];
      final slot = digits.indexOf(key);
      if (slot >= 0) input.selectWeapon = slot;
    } else if (event is KeyUpEvent) {
      _keys.remove(key);
    }
    _syncMove();
    return KeyEventResult.handled;
  }

  void _look(Offset delta) {
    input.lookX += delta.dx;
    input.lookY += delta.dy;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          // Right half: drag to look around.
          Positioned(
            right: 0, top: 0, bottom: 0,
            width: MediaQuery.sizeOf(context).width / 2,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _focus.requestFocus(),
              onPointerMove: (e) => _look(e.delta),
              onPointerSignal: (e) {
                if (e is PointerScrollEvent) input.aim = e.scrollDelta.dy < 0;
              },
            ),
          ),
          // Movement stick, bottom left. Pushing it to the rim sprints. Kept
          // outside the per-frame builder so a held drag is never reset.
          Positioned(
            left: 36, bottom: 36,
            child: VirtualJoystick(
              radius: 64,
              knobRadius: 26,
              onChanged: (dir) {
                _stick = dir;
                _syncMove();
              },
            ),
          ),
          ValueListenableBuilder<int>(
            valueListenable: game.frame,
            builder: (context, _, _) => _overlay(context),
          ),
        ],
      ),
    );
  }

  Widget _overlay(BuildContext context) {
    final player = game.player;
    final br = game.br;
    final mode = player.controller.mode;
    final children = <Widget>[];

    if (player.hurtTime < 0.35 && player.alive) children.add(const _DamageVignette());

    if (mode == MoveMode.ground && player.alive) {
      children.addAll(_combatControls(player));
    } else if (mode == MoveMode.plane) {
      children.add(Positioned(
        bottom: 60, left: 0, right: 0,
        child: Center(child: _BigButton(label: 'JUMP', onTap: () => input.jump = true)),
      ));
      children.add(Positioned(
        top: 64, left: 0, right: 0,
        child: Center(child: _Panel(child: Text('${br?.aboardCount ?? 0} players still on the plane  ·  pick your drop spot', style: _small))),
      ));
    } else if (mode == MoveMode.freefall || mode == MoveMode.parachute) {
      final c = player.controller;
      children.add(Positioned(
        top: 64, left: 0, right: 0,
        child: Center(child: _Panel(child: Text('Altitude ${c.heightAboveGround.round()} m', style: _small))),
      ));
      if (c.canOpenParachute) {
        children.add(Positioned(
          bottom: 60, left: 0, right: 0,
          child: Center(child: _BigButton(label: 'OPEN PARACHUTE', onTap: () => input.jump = true)),
        ));
      }
    }

    if (br != null) {
      children.addAll(_battleRoyaleInfo(br));
      if (!player.alive || br.phase == MatchPhase.ended) children.add(_results(br));
    } else {
      children.add(Positioned(
        top: 14, left: 16,
        child: _Panel(
          child: Text(
            'Targets down  ${game.knockdowns}\n'
            'Accuracy  ${game.shots == 0 ? '-' : '${(100 * game.hits / game.shots).round()}%'}',
            style: _small,
          ),
        ),
      ));
      children.add(Positioned(
        bottom: 16, left: 190,
        child: _SmallButton(label: 'Menu', icon: Icons.home, onTap: widget.onExit),
      ));
    }
    return Stack(children: children);
  }

  List<Widget> _combatControls(Combatant player) {
    final weapon = player.weapon;
    final swap = game.br?.swapCandidate;
    return [
      if (player.armed) const Center(child: _Crosshair()),
      if (game.hitMarker > 0) Center(child: _HitMarker(headshot: game.lastHitHead)),
      // Weapon slots, top center.
      Positioned(
        top: 12, left: 0, right: 0,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < player.slots.length; i++)
              _WeaponSlot(
                name: player.slots[i]?.spec.name ?? 'Empty',
                slot: i + 1,
                selected: i == player.current && player.slots[i] != null,
                onTap: () => input.selectWeapon = i,
              ),
          ],
        ),
      ),
      // Health, ammo and status, bottom center.
      Positioned(
        bottom: 18, left: 0, right: 0,
        child: Column(
          children: [
            if (weapon?.reloading ?? false) _Progress(label: 'RELOADING', value: 1 - weapon!.reloadLeft / weapon.spec.reloadTime),
            if (player.healing) _Progress(label: 'HEALING', value: player.healProgress, color: Colors.greenAccent),
            const SizedBox(height: 4),
            if (weapon != null)
              Text.rich(TextSpan(children: [
                TextSpan(text: '${weapon.ammo}', style: _big.copyWith(color: weapon.ammo == 0 ? Colors.redAccent : Colors.white)),
                TextSpan(text: ' / ${weapon.reserve}', style: _small),
              ]))
            else
              const Text('Find a gun!', style: _small),
            const SizedBox(height: 4),
            _HealthBar(health: player.health),
          ],
        ),
      ),
      // Action buttons, bottom right.
      Positioned(
        right: 28, bottom: 40,
        child: _HoldButton(
          size: 92,
          icon: Icons.gps_fixed,
          color: const Color(0xCCD9462B),
          onDown: () {
            _fireTouches++;
            _syncMove();
          },
          onUp: () {
            _fireTouches--;
            _syncMove();
          },
          // Dragging on the fire button aims at the same time, like on
          // most mobile shooters.
          onDrag: _look,
        ),
      ),
      Positioned(
        right: 136, bottom: 30,
        child: _TapButton(icon: Icons.keyboard_double_arrow_up, label: 'Jump', onTap: () => input.jump = true),
      ),
      Positioned(
        right: 132, bottom: 110,
        child: _TapButton(
          icon: Icons.center_focus_strong,
          label: 'Aim',
          active: input.aim,
          onTap: () => input.aim = !input.aim,
        ),
      ),
      Positioned(
        right: 40, bottom: 150,
        child: _TapButton(icon: Icons.autorenew, label: 'Reload', onTap: () => input.reload = true),
      ),
      if (game.br != null)
        Positioned(
          right: 118, bottom: 186,
          child: _TapButton(
            icon: Icons.medical_services,
            label: '${player.medkits}',
            active: player.healing,
            onTap: () => input.heal = true,
          ),
        ),
      if (swap != null)
        Positioned(
          right: 210, bottom: 120,
          child: _SmallButton(
            label: 'Swap for ${swap.label}',
            icon: Icons.swap_horiz,
            onTap: () => input.pickup = true,
          ),
        ),
    ];
  }

  List<Widget> _battleRoyaleInfo(BattleRoyale br) {
    final zone = br.zone;
    final zoneText = switch (br.phase) {
      MatchPhase.plane => 'Safe zone appears after the drop',
      MatchPhase.ended => 'Match over',
      MatchPhase.battle when zone.finished => 'Final zone',
      MatchPhase.battle when zone.shrinking => 'Zone shrinking  ${formatSeconds(zone.secondsLeft)}',
      MatchPhase.battle => 'Zone shrinks in  ${formatSeconds(zone.secondsLeft)}',
    };
    final outside = br.phase == MatchPhase.battle && game.player.alive && !zone.contains(game.player.position.x, game.player.position.z);
    return [
      Positioned(
        top: 14, left: 16,
        child: _Panel(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.person, color: Colors.white, size: 16),
            Text(' ${br.aliveCount} alive', style: _small),
            const SizedBox(width: 12),
            const Icon(Icons.gps_fixed, color: Colors.white, size: 15),
            Text(' ${game.player.kills} kills', style: _small),
          ]),
        ),
      ),
      Positioned(
        top: 12, right: 14,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Minimap(game: game),
            const SizedBox(height: 4),
            _Panel(child: Text(zoneText, style: _small.copyWith(color: outside ? Colors.redAccent : Colors.white))),
            const SizedBox(height: 6),
            for (final e in br.killFeed) _KillFeedRow(entry: e),
          ],
        ),
      ),
      if (outside)
        const Positioned(
          top: 64, left: 0, right: 0,
          child: Center(child: _Panel(child: Text('You are outside the safe zone! Get inside.', style: _warn))),
        ),
    ];
  }

  Widget _results(BattleRoyale br) {
    final player = game.player;
    final won = identical(br.winner, player);
    final killer = player.lastAttacker;
    final title = won ? 'BOOYAH!' : '#${player.placement ?? br.aliveCount}';
    final subtitle = won
        ? 'Winner winner! You are the last one standing.'
        : player.alive
        ? 'Match over'
        : killer != null && killer.alive
        ? 'Eliminated by ${killer.name}  ·  spectating'
        : killer != null
        ? 'Eliminated by ${killer.name}'
        : 'Lost to the zone';
    return Positioned.fill(
      child: Container(
        color: won ? const Color(0x66000000) : const Color(0x88000000),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: TextStyle(
                fontSize: won ? 64 : 56, fontWeight: FontWeight.w900, letterSpacing: 2,
                color: won ? const Color(0xFFFFC94A) : Colors.white,
                shadows: const [Shadow(blurRadius: 12)],
              )),
              const SizedBox(height: 6),
              Text(subtitle, style: _small.copyWith(fontSize: 16)),
              const SizedBox(height: 4),
              Text('${player.kills} kills  ·  placed ${player.placement ?? '-'} of ${BattleRoyale.playerCount}', style: _small),
              const SizedBox(height: 22),
              Row(mainAxisSize: MainAxisSize.min, children: [
                _SmallButton(label: 'Play again', icon: Icons.replay, onTap: widget.onRestart),
                const SizedBox(width: 12),
                _SmallButton(label: 'Main menu', icon: Icons.home, onTap: widget.onExit),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

const _small = TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, shadows: [Shadow(blurRadius: 3)]);
const _big = TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, shadows: [Shadow(blurRadius: 4)]);
const _warn = TextStyle(color: Colors.redAccent, fontSize: 14, fontWeight: FontWeight.w800, shadows: [Shadow(blurRadius: 3)]);

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(6)),
    child: child,
  );
}

class _KillFeedRow extends StatelessWidget {
  const _KillFeedRow({required this.entry});
  final KillFeedEntry entry;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 3),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(4)),
    child: Text.rich(
      TextSpan(children: [
        TextSpan(text: entry.killer ?? 'Zone', style: _small.copyWith(color: const Color(0xFFFFC94A), fontSize: 11)),
        TextSpan(text: '  [${entry.weapon}]', style: _small.copyWith(fontSize: 11, color: Colors.white70)),
        if (entry.headshot) TextSpan(text: ' HEADSHOT', style: _small.copyWith(fontSize: 10, color: Colors.redAccent)),
        const TextSpan(text: '  '),
        TextSpan(text: entry.victim, style: _small.copyWith(fontSize: 11)),
      ]),
    ),
  );
}

class _HealthBar extends StatelessWidget {
  const _HealthBar({required this.health});
  final double health;
  @override
  Widget build(BuildContext context) {
    final f = (health / Combatant.maxHealth).clamp(0.0, 1.0);
    return Container(
      width: 220,
      height: 12,
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(3), border: Border.all(color: Colors.white38)),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: f,
        child: Container(color: Color.lerp(Colors.redAccent, const Color(0xFF6BE36B), f)),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.label, required this.value, this.color = Colors.amber});
  final String label;
  final double value;
  final Color color;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 140,
    child: Column(children: [
      Text(label, style: _small),
      const SizedBox(height: 3),
      LinearProgressIndicator(value: value, color: color, backgroundColor: Colors.white24),
    ]),
  );
}

class _DamageVignette extends StatelessWidget {
  const _DamageVignette();
  @override
  Widget build(BuildContext context) => const IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(colors: [Color(0x00FF0000), Color(0x66FF0000)], stops: [0.6, 1]),
      ),
      child: SizedBox.expand(),
    ),
  );
}

class _Crosshair extends StatelessWidget {
  const _Crosshair();
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(size: const Size(28, 28), painter: _CrosshairPainter()),
  );
}

class _CrosshairPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final shadow = Paint()..color = Colors.black54..strokeWidth = 3.5;
    final line = Paint()..color = Colors.white..strokeWidth = 1.8;
    for (final p in [shadow, line]) {
      canvas.drawLine(c + const Offset(-13, 0), c + const Offset(-5, 0), p);
      canvas.drawLine(c + const Offset(5, 0), c + const Offset(13, 0), p);
      canvas.drawLine(c + const Offset(0, -13), c + const Offset(0, -5), p);
      canvas.drawLine(c + const Offset(0, 5), c + const Offset(0, 13), p);
    }
    canvas.drawCircle(c, 1.6, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _HitMarker extends StatelessWidget {
  const _HitMarker({required this.headshot});
  final bool headshot;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(size: const Size(44, 44), painter: _HitPainter(headshot ? Colors.redAccent : Colors.white)),
  );
}

class _HitPainter extends CustomPainter {
  _HitPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final p = Paint()..color = color..strokeWidth = 2.6;
    for (final d in const [Offset(1, 1), Offset(-1, 1), Offset(1, -1), Offset(-1, -1)]) {
      canvas.drawLine(c + d * 9, c + d * 17, p);
    }
  }

  @override
  bool shouldRepaint(covariant _HitPainter old) => old.color != color;
}

class _WeaponSlot extends StatelessWidget {
  const _WeaponSlot({required this.name, required this.slot, required this.selected, required this.onTap});
  final String name;
  final int slot;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? const Color(0xDDE08A2C) : Colors.black45,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: selected ? Colors.white : Colors.white24),
      ),
      child: Text('$slot  $name', style: _small),
    ),
  );
}

class _TapButton extends StatelessWidget {
  const _TapButton({required this.icon, required this.label, required this.onTap, this.active = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) => onTap(),
    child: Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? const Color(0xCCE08A2C) : Colors.black38,
        border: Border.all(color: Colors.white54, width: 2),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white, size: 24),
          Text(label, style: _small.copyWith(fontSize: 10)),
        ],
      ),
    ),
  );
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({required this.label, required this.icon, required this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xDDE08A2C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white70),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: Colors.white, size: 18),
        const SizedBox(width: 6),
        Text(label, style: _small.copyWith(fontSize: 14)),
      ]),
    ),
  );
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) => onTap(),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 42, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xEEE0632C),
        borderRadius: BorderRadius.circular(40),
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black45)],
      ),
      child: Text(label, style: _big.copyWith(fontSize: 24, letterSpacing: 2)),
    ),
  );
}

/// A button that reports press and release separately (multi-touch safe) and
/// forwards finger drags while held.
class _HoldButton extends StatefulWidget {
  const _HoldButton({required this.size, required this.icon, required this.color, required this.onDown, required this.onUp, required this.onDrag});
  final double size;
  final IconData icon;
  final Color color;
  final VoidCallback onDown;
  final VoidCallback onUp;
  final ValueChanged<Offset> onDrag;

  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> {
  int _pointers = 0;

  @override
  void dispose() {
    // Released by being removed (e.g. the player died while firing).
    for (var i = 0; i < _pointers; i++) {
      widget.onUp();
    }
    super.dispose();
  }

  void _release() {
    if (_pointers == 0) return;
    _pointers--;
    widget.onUp();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (_) {
      _pointers++;
      widget.onDown();
      setState(() {});
    },
    onPointerMove: (e) => widget.onDrag(e.delta),
    onPointerUp: (_) => _release(),
    onPointerCancel: (_) => _release(),
    child: Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _pointers > 0 ? widget.color.withValues(alpha: 1) : widget.color,
        border: Border.all(color: Colors.white70, width: 3),
      ),
      child: Icon(widget.icon, color: Colors.white, size: widget.size * 0.45),
    ),
  );
}
