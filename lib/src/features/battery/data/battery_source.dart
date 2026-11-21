import 'package:flutter/services.dart';

import '../domain/battery_prompt.dart';

/// The phone's battery saver, as far as it concerns this app.
abstract interface class BatterySource {
  /// Whether the battery saver may put the app to sleep, and the phone's
  /// maker, or null when the phone cannot say.
  Future<BatteryStatus?> status();

  /// Opens this app's page in Settings (where Battery › Unrestricted is),
  /// or else the battery optimisation list. False when neither opens.
  Future<bool> openSettings();
}

/// [BatterySource] backed by `BatteryChannel.kt`. Android only; no Google
/// libraries, so it works the same in the F-Droid build.
class PlatformBatterySource implements BatterySource {
  const PlatformBatterySource([
    this._channel = const MethodChannel('com.pesaclarity.app/battery'),
  ]);

  final MethodChannel _channel;

  @override
  Future<BatteryStatus?> status() async {
    try {
      final ignoring = await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      if (ignoring == null) return null;
      final maker = await _channel.invokeMethod<String>('manufacturer');
      return BatteryStatus(restricted: !ignoring, manufacturer: maker ?? '');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> openSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
