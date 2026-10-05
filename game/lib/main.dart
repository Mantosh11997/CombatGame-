import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';

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
    home: const GameScreen(),
  );
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  final Game game = Game();
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

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(body: Center(child: Text('Failed to load: $_error')));
    }
    if (!_ready) {
      return const Scaffold(
        backgroundColor: Color(0xFF15171A),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('COMBAT GAME', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 4)),
              SizedBox(height: 16),
              SizedBox(width: 160, child: LinearProgressIndicator()),
              SizedBox(height: 8),
              Text('Loading Training Island...'),
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
          Hud(game: game),
        ],
      ),
    );
  }
}
