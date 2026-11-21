import 'package:pesaclarity/src/features/battery/data/battery_source.dart';
import 'package:pesaclarity/src/features/battery/domain/battery_prompt.dart';

/// A phone whose battery setting the test changes, as the person would in
/// Settings. Records what was asked of it.
class FakeBatterySource implements BatterySource {
  FakeBatterySource({
    bool restricted = true,
    this.manufacturer = 'samsung',
    this.opens = true,
  }) : current = BatteryStatus(
         restricted: restricted,
         manufacturer: manufacturer,
       );

  final String manufacturer;

  /// What the phone says now; null when it cannot say.
  BatteryStatus? current;

  /// Whether Settings opens.
  bool opens;

  int asked = 0;
  int settingsOpened = 0;

  /// The person changed the setting.
  set restricted(bool value) =>
      current = BatteryStatus(restricted: value, manufacturer: manufacturer);

  @override
  Future<BatteryStatus?> status() async {
    asked++;
    return current;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return opens;
  }
}
