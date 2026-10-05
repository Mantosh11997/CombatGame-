import 'package:combat_game/game/weapons.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WeaponState rifle() => WeaponState(weaponSpecs.firstWhere((s) => s.id == 'assault_rifle'));

  int holdTrigger(WeaponState w, double seconds, double frame) {
    var shots = 0;
    for (var t = 0.0; t < seconds - 1e-9; t += frame) {
      w.update(frame);
      while (shots < 1000 && w.tryFire()) {
        shots++;
      }
    }
    return shots;
  }

  test('fire rate is the same at 60 fps and 10 fps', () {
    // 0.1 s per shot: 1 second of trigger is 10 shots either way.
    expect(holdTrigger(rifle(), 1.0, 1 / 60), 10);
    expect(holdTrigger(rifle(), 1.0, 1 / 10), 10);
  });

  test('empty magazine reloads from reserve', () {
    final w = rifle();
    holdTrigger(w, 3.5, 1 / 60); // 30 rounds take 3 s; reload takes 2 s
    expect(w.ammo, 0);
    expect(w.reloading, isTrue);
    w.update(w.spec.reloadTime + 0.01);
    expect(w.ammo, w.spec.magazine);
    expect(w.reserve, w.spec.reserve - w.spec.magazine);
  });

  test('releasing the trigger does not bank shots', () {
    final w = rifle();
    w.update(2);
    w.settle();
    expect(w.tryFire(), isTrue);
    expect(w.tryFire(), isFalse);
  });
}
