import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/time/clock.dart';
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/data/repositories/app_settings_repository.dart';
import 'package:pesaclarity/src/features/accounts/domain/institution.dart';
import 'package:pesaclarity/src/features/battery/application/battery_providers.dart';
import 'package:pesaclarity/src/features/battery/domain/battery_prompt.dart';
import 'package:pesaclarity/src/features/sms/application/sms_capture_providers.dart';
import 'package:pesaclarity/src/features/sms/data/sms_source.dart';

import '../../helpers/fake_battery_source.dart';
import '../../helpers/fake_sms_source.dart';
import '../../helpers/test_app.dart';

final _now = DateTime.utc(2026, 11, 21, 6);

const _restricted = BatteryStatus(restricted: true, manufacturer: 'samsung');
const _free = BatteryStatus(restricted: false, manufacturer: 'samsung');

void main() {
  group('showBatteryCard', () {
    bool show({
      bool android = true,
      bool smsReady = true,
      BatteryStatus? status = _restricted,
      DateTime? notNowAt,
    }) => showBatteryCard(
      android: android,
      smsReady: smsReady,
      status: status,
      prompt: BatteryPromptState(notNowAt: notNowAt),
      now: _now,
    );

    test('shows while restricted and messages are being read', () {
      expect(show(), isTrue);
    });

    test('hides once the app is no longer restricted', () {
      expect(show(status: _free), isFalse);
    });

    test('hides when the phone cannot say', () {
      expect(show(status: null), isFalse);
    });

    test('hides until messages are being read', () {
      expect(show(smsReady: false), isFalse);
    });

    test('never shows on iPhone', () {
      expect(show(android: false), isFalse);
    });

    test('"Not now" hides it for 7 days', () {
      expect(show(notNowAt: _now), isFalse);
      expect(
        show(notNowAt: _now.subtract(const Duration(days: 6, hours: 23))),
        isFalse,
      );
    });

    test('after 7 days it comes back, only if still restricted', () {
      final weekAgo = _now.subtract(batteryNotNowFor);
      expect(show(notNowAt: weekAgo), isTrue);
      expect(
        show(notNowAt: weekAgo.subtract(const Duration(days: 30))),
        isTrue,
      );
      expect(show(notNowAt: weekAgo, status: _free), isFalse);
    });
  });

  group('BatterySteps', () {
    test('Samsung gets its exact paths and the sleeping lists', () {
      final text = BatterySteps.forPhone(_restricted);
      expect(text.steps.map((s) => s.title), [
        'Let it run in the background',
        'Take it off the sleeping lists',
        'Come back here',
      ]);
      expect(text.steps[0].path, [
        'Settings',
        'Apps',
        'Pesa Clarity',
        'Battery',
        'Unrestricted',
      ]);
      expect(text.steps[1].path, [
        'Settings',
        'Battery',
        'Background usage limits',
      ]);
      expect(text.intro, startsWith('Samsung puts apps to sleep'));
    });

    test('other phones get the usual path and no sleeping lists', () {
      for (final maker in ['Google', 'TECNO', 'Infinix', '']) {
        final text = BatterySteps.forPhone(
          BatteryStatus(restricted: true, manufacturer: maker),
        );
        expect(text.steps, hasLength(2), reason: maker);
        expect(
          text.steps.map((s) => s.title),
          isNot(contains('Take it off the sleeping lists')),
        );
        expect(text.steps.first.detail, contains("Don't optimise"));
      }
      expect(BatterySteps.forPhone(null), BatterySteps.other);
    });

    test('Samsung is matched whatever the case', () {
      expect(
        const BatteryStatus(
          restricted: true,
          manufacturer: 'SAMSUNG',
        ).isSamsung,
        isTrue,
      );
    });
  });

  test('the "Not now" time survives a round trip', () {
    final state = BatteryPromptState(notNowAt: _now);
    expect(BatteryPromptState.fromJson(state.toJson()).notNowAt, _now);
    expect(BatteryPromptState.fromJson(null).notNowAt, isNull);
    expect(
      BatteryPromptState.fromJson(const {'notNowAt': 'nonsense'}).notNowAt,
      isNull,
    );
  });

  group('batteryCardShownProvider', () {
    late FakeBatterySource battery;
    late FakeSmsSource sms;
    late DateTime now;

    ProviderContainer container({
      bool android = true,
      bool accounts = true,
      SmsSource? smsSource,
    }) {
      final db = openTestDatabase();
      final c = ProviderContainer(
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => now),
          batteryIsAndroidProvider.overrideWithValue(android),
          batterySourceProvider.overrideWithValue(battery),
          smsSourceProvider.overrideWithValue(smsSource ?? sms),
          selectedInstitutionsProvider.overrideWith(
            (ref) => accounts
                ? [ref.watch(institutionCatalogueProvider).first]
                : const [],
          ),
        ],
      );
      addTearDown(c.dispose);
      c.listen(batteryCardShownProvider, (_, _) {});
      return c;
    }

    Future<bool> shown(ProviderContainer c) async {
      await c.read(batteryStatusProvider.future);
      await c.read(smsReadingReadyProvider.future);
      await c.read(batteryPromptProvider.future);
      return c.read(batteryCardShownProvider);
    }

    setUp(() {
      battery = FakeBatterySource();
      sms = FakeSmsSource();
      now = _now;
    });

    test(
      'shows when restricted with SMS allowed and accounts chosen',
      () async {
        expect(await shown(container()), isTrue);
      },
    );

    test('hides when not restricted', () async {
      battery.restricted = false;
      expect(await shown(container()), isFalse);
    });

    test('hides without SMS permission or accounts', () async {
      sms.current = SmsAccess.denied;
      expect(await shown(container()), isFalse);
      sms.current = SmsAccess.granted;
      expect(await shown(container(accounts: false)), isFalse);
    });

    test('never asks the phone on iPhone', () async {
      expect(
        await shown(
          container(android: false, smsSource: const ShortcutSmsSource()),
        ),
        isFalse,
      );
      expect(battery.asked, 0);
    });

    test('"Not now" is saved and lasts 7 days', () async {
      final c = container();
      expect(await shown(c), isTrue);
      await c.read(batteryPromptProvider.notifier).notNow();
      expect(c.read(batteryCardShownProvider), isFalse);

      final saved = await c
          .read(mainSettingsRepositoryProvider)
          .readJson(BatteryPromptController.settingsKey);
      expect(BatteryPromptState.fromJson(saved).notNowAt, _now);

      // A fresh start a day later still remembers it.
      now = _now.add(const Duration(days: 1));
      c.invalidate(batteryPromptProvider);
      expect(await shown(c), isFalse);

      now = _now.add(batteryNotNowFor);
      c.invalidate(batteryCardShownProvider);
      expect(await shown(c), isTrue);
    });

    test('a recheck hides it once fixed in Settings', () async {
      final c = container();
      expect(await shown(c), isTrue);
      battery.restricted = false;
      c.invalidate(batteryStatusProvider);
      expect(await shown(c), isFalse);
      expect(battery.asked, 2);
    });
  });
}
