/// Static stats for every gun. Asset names match the exported .glb files.
class WeaponSpec {
  const WeaponSpec({
    required this.id,
    required this.name,
    required this.damage,
    required this.fireInterval,
    required this.magazine,
    required this.reserve,
    required this.reloadTime,
    required this.spread,
    this.pellets = 1,
    this.automatic = false,
    this.range = 120,
    this.recoil = 0.012,
    this.zoom = 1,
  });

  final String id;
  final String name;
  final double damage;

  /// Seconds between shots.
  final double fireInterval;
  final int magazine;
  final int reserve;
  final double reloadTime;

  /// Random aim cone half-angle in radians.
  final double spread;
  final int pellets;
  final bool automatic;
  final double range;

  /// Camera pitch kick per shot, radians.
  final double recoil;

  /// Field-of-view divisor while aiming down sights.
  final double zoom;

  String get asset => 'assets/models/$id.glb';

  /// Single-mesh low-detail model, for bots and loot on the ground.
  String get lowAsset => 'assets/models/${id}_lod.glb';
}

const weaponSpecs = <WeaponSpec>[
  WeaponSpec(
    id: 'assault_rifle', name: 'AR', damage: 30, fireInterval: 0.1,
    magazine: 30, reserve: 120, reloadTime: 2.0, spread: 0.012,
    automatic: true, zoom: 1.6,
  ),
  WeaponSpec(
    id: 'machine_gun', name: 'MG', damage: 28, fireInterval: 0.075,
    magazine: 100, reserve: 200, reloadTime: 4.0, spread: 0.025,
    automatic: true, recoil: 0.009, zoom: 1.4,
  ),
  WeaponSpec(
    id: 'shotgun', name: 'Shotgun', damage: 18, fireInterval: 0.9,
    magazine: 6, reserve: 30, reloadTime: 2.6, spread: 0.07, pellets: 8,
    range: 35, recoil: 0.04,
  ),
  WeaponSpec(
    id: 'sniper_rifle', name: 'Sniper', damage: 95, fireInterval: 1.3,
    magazine: 5, reserve: 25, reloadTime: 3.0, spread: 0.0, range: 400,
    recoil: 0.05, zoom: 4,
  ),
  WeaponSpec(
    id: 'pistol', name: 'Pistol', damage: 25, fireInterval: 0.22,
    magazine: 15, reserve: 60, reloadTime: 1.4, spread: 0.015, range: 60,
    recoil: 0.02,
  ),
];

/// Ammo and timing state for one carried gun.
class WeaponState {
  WeaponState(this.spec) : ammo = spec.magazine, reserve = spec.reserve;

  final WeaponSpec spec;
  int ammo;
  int reserve;
  double cooldown = 0;
  double reloadLeft = 0;

  bool get reloading => reloadLeft > 0;
  bool get canFire => cooldown <= 0 && !reloading && ammo > 0;

  void startReload() {
    if (reloading || ammo == spec.magazine || reserve == 0) return;
    reloadLeft = spec.reloadTime;
  }

  void cancelReload() => reloadLeft = 0;

  /// Trigger released: drop any owed time so idling cannot bank a burst.
  void settle() {
    if (cooldown < 0) cooldown = 0;
  }

  void update(double dt) {
    if (cooldown > 0) cooldown -= dt;
    if (reloadLeft > 0) {
      reloadLeft -= dt;
      if (reloadLeft <= 0) {
        reloadLeft = 0;
        final take = (spec.magazine - ammo).clamp(0, reserve);
        ammo += take;
        reserve -= take;
      }
    }
  }

  /// Consumes one round. Returns false when the gun cannot fire now.
  bool tryFire() {
    if (!canFire) return false;
    ammo--;
    // Carry over time already owed, so the fire rate holds at any frame rate.
    cooldown += spec.fireInterval;
    if (ammo == 0) startReload();
    return true;
  }
}
