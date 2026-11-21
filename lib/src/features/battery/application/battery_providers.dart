import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/repositories/app_settings_repository.dart';
import '../../sms/application/sms_capture_providers.dart';
import '../../sms/data/sms_source.dart';
import '../data/battery_source.dart';
import '../domain/battery_prompt.dart';

/// Whether this is an Android phone. iPhone has no battery saver that stops
/// messages: they come through Shortcuts, so the card never shows there.
final batteryIsAndroidProvider = Provider<bool>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
);

final batterySourceProvider = Provider<BatterySource>(
  (ref) => const PlatformBatterySource(),
);

/// The battery saver's hold on the app, or null off Android or when the
/// phone cannot say. Checked again with [recheckBattery].
final batteryStatusProvider = FutureProvider<BatteryStatus?>((ref) async {
  if (!ref.watch(batteryIsAndroidProvider)) return null;
  return ref.watch(batterySourceProvider).status();
});

/// Messages are being read: at least one account is switched on and the
/// app may read SMS.
final smsReadingReadyProvider = FutureProvider<bool>((ref) async {
  final source = ref.watch(smsSourceProvider);
  if (source is ShortcutSmsSource) return false;
  if (ref.watch(selectedInstitutionsProvider).isEmpty) return false;
  return await source.access() == SmsAccess.granted;
});

/// Asks the phone again, as when the app comes back to the front after the
/// person changed its battery setting or SMS permission in Settings.
void recheckBattery(WidgetRef ref) {
  ref.invalidate(batteryStatusProvider);
  ref.invalidate(smsReadingReadyProvider);
}

/// When "Not now" was tapped, kept with Personal.
class BatteryPromptController extends AsyncNotifier<BatteryPromptState> {
  static const settingsKey = 'battery.prompt';

  @override
  Future<BatteryPromptState> build() async => BatteryPromptState.fromJson(
    await ref.watch(mainSettingsRepositoryProvider).readJson(settingsKey),
  );

  /// Hides the card for [batteryNotNowFor].
  Future<void> notNow() async {
    final next = BatteryPromptState(notNowAt: ref.read(clockProvider)());
    state = AsyncData(next);
    await ref
        .read(mainSettingsRepositoryProvider)
        .writeJson(settingsKey, next.toJson());
  }
}

final batteryPromptProvider =
    AsyncNotifierProvider<BatteryPromptController, BatteryPromptState>(
      BatteryPromptController.new,
    );

/// Whether Home shows "Messages may be missed" (see [showBatteryCard]).
/// Nothing is read from the database unless the app is restricted.
final batteryCardShownProvider = Provider<bool>((ref) {
  final status = ref.watch(batteryStatusProvider).value;
  if (status == null || !status.restricted) return false;
  final ready = ref.watch(smsReadingReadyProvider).value ?? false;
  final prompt = ref.watch(batteryPromptProvider).value;
  if (!ready || prompt == null) return false;
  return showBatteryCard(
    android: ref.watch(batteryIsAndroidProvider),
    smsReady: ready,
    status: status,
    prompt: prompt,
    now: ref.watch(clockProvider)(),
  );
});
