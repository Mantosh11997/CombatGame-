import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';

import 'game/battle_royale.dart';
import 'game/game.dart';
import 'ui/hud.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const CombatGameApp());
}

class CombatGameApp extends StatelessWidget {
  const CombatGameApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CombatGame',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: const MenuScreen(),
  );
}

class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  static bool _autoStarted = false;

  void _start(BuildContext context, GameMode mode) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => GameScreen(mode: mode)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Debug/automation shortcut: ?mode=training or ?mode=br skips the menu
    // (once, so returning to the menu stays on the menu).
    final auto = Uri.base.queryParameters['mode'];
    if (auto != null && !_autoStarted) {
      _autoStarted = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _start(context, auto == 'training' ? GameMode.training : GameMode.battleRoyale),
      );
    }
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1F3A5C), Color(0xFF6E8FB0), Color(0xFFCBB98A)],
            stops: [0, 0.65, 1],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('COMBAT GAME', style: TextStyle(
                fontSize: 52, fontWeight: FontWeight.w900, letterSpacing: 6, color: Colors.white,
                shadows: [Shadow(blurRadius: 16, color: Colors.black54)],
              )),
              const SizedBox(height: 6),
              const Text('Training Island  ·  ${BattleRoyale.playerCount} players  ·  last one standing wins',
                  style: TextStyle(fontSize: 15, color: Colors.white70)),
              const SizedBox(height: 34),
              _MenuButton(
                label: 'START',
                subtitle: 'Battle royale match',
                primary: true,
                onTap: () => _start(context, GameMode.battleRoyale),
              ),
              const SizedBox(height: 14),
              _MenuButton(
                label: 'TRAINING',
                subtitle: 'Firing range with every gun',
                onTap: () => _start(context, GameMode.training),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.label, required this.subtitle, required this.onTap, this.primary = false});
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 280,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: primary ? const Color(0xFFE0632C) : const Color(0xCC1D2024),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white, width: primary ? 3 : 1.5),
        boxShadow: const [BoxShadow(blurRadius: 14, color: Colors.black38)],
      ),
      child: Column(children: [
        Text(label, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 4, color: Colors.white)),
        Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.white70)),
      ]),
    ),
  );
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key, required this.mode});
  final GameMode mode;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late final Game game = Game(widget.mode);
  bool _ready = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    game.load().then(
      (_) {
        if (mounted) setState(() => _ready = true);
      },
      onError: (Object e, StackTrace s) {
        debugPrint('Game failed to load: $e\n$s');
        if (mounted) setState(() => _error = e);
      },
    );
  }

  void _go(Widget screen) {
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(body: Center(child: Text('Failed to load: $_error')));
    }
    if (!_ready) {
      return Scaffold(
        backgroundColor: const Color(0xFF15171A),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('COMBAT GAME', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 4)),
              const SizedBox(height: 16),
              const SizedBox(width: 160, child: LinearProgressIndicator()),
              const SizedBox(height: 8),
              Text(widget.mode == GameMode.battleRoyale
                  ? 'Boarding ${BattleRoyale.playerCount} players...'
                  : 'Loading Training Island...'),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          SceneView(
            game.scene,
            cameraBuilder: (_) => game.camera(),
            onTick: (_, dt) => game.tick(dt),
          ),
          Hud(
            game: game,
            onExit: () => _go(const MenuScreen()),
            onRestart: () => _go(GameScreen(mode: widget.mode)),
          ),
        ],
      ),
    );
  }
}
