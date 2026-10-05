import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/kit.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../game/game.dart';
import '../game/weapons.dart';

/// Touch controls and readouts drawn over the 3D view. On a keyboard:
/// WASD move, Shift sprint, Space jump, R reload, 1-5 guns, F fire,
/// Q aim; drag anywhere on the right half to look.
class Hud extends StatefulWidget {
  const Hud({super.key, required this.game});
  final Game game;

  @override
  State<Hud> createState() => _HudState();
}

class _HudState extends State<Hud> {
  GameInput get input => widget.game.input;
  final _keys = <LogicalKeyboardKey>{};
  vm.Vector2 _stick = vm.Vector2.zero();
  final _focus = FocusNode();

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
      if (key == LogicalKeyboardKey.keyQ) setState(() => input.aim = !input.aim);
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

  int _fireTouches = 0;

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
                if (e is PointerScrollEvent) setState(() => input.aim = e.scrollDelta.dy < 0);
              },
            ),
          ),
          const Center(child: _Crosshair()),
          ValueListenableBuilder<HudState?>(
            valueListenable: widget.game.hud,
            builder: (context, hud, _) => hud == null ? const SizedBox() : _readouts(hud),
          ),
          // Movement stick, bottom left. Pushing it to the rim sprints.
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
              onTap: () => setState(() => input.aim = !input.aim),
            ),
          ),
          Positioned(
            right: 40, bottom: 150,
            child: _TapButton(icon: Icons.autorenew, label: 'Reload', onTap: () => input.reload = true),
          ),
        ],
      ),
    );
  }

  Widget _readouts(HudState hud) {
    final spec = weaponSpecs[hud.weapon];
    return Stack(
      children: [
        if (hud.hitMarker) Center(child: _HitMarker(headshot: hud.headshot)),
        // Weapon slots, top center.
        Positioned(
          top: 12, left: 0, right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < weaponSpecs.length; i++)
                _WeaponSlot(
                  name: weaponSpecs[i].name,
                  slot: i + 1,
                  selected: i == hud.weapon,
                  onTap: () => input.selectWeapon = i,
                ),
            ],
          ),
        ),
        // Ammo, bottom center.
        Positioned(
          bottom: 22, left: 0, right: 0,
          child: Column(
            children: [
              if (hud.reload > 0)
                SizedBox(
                  width: 140,
                  child: Column(children: [
                    const Text('RELOADING', style: _small),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: hud.reload, color: Colors.amber, backgroundColor: Colors.white24),
                  ]),
                ),
              const SizedBox(height: 6),
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: '${hud.ammo}', style: _big.copyWith(color: hud.ammo == 0 ? Colors.redAccent : Colors.white)),
                  TextSpan(text: ' / ${hud.reserve}', style: _small),
                ]),
              ),
              Text(spec.name.toUpperCase(), style: _small),
            ],
          ),
        ),
        // Stats, top left.
        Positioned(
          top: 14, left: 16,
          child: _Panel(
            child: Text(
              'Targets down  ${hud.knockdowns}\n'
              'Accuracy  ${hud.shots == 0 ? '-' : '${(100 * hud.hits / hud.shots).round()}%'}',
              style: _small,
            ),
          ),
        ),
      ],
    );
  }
}

const _small = TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, shadows: [Shadow(blurRadius: 3)]);
const _big = TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, shadows: [Shadow(blurRadius: 4)]);

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(6)),
    child: child,
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
