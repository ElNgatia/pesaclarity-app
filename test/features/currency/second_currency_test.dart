import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/money/exchange_rates.dart';
import 'package:pesaclarity/src/core/money/money.dart';
import 'package:pesaclarity/src/core/time/clock.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/data/repositories/app_settings_repository.dart';
import 'package:pesaclarity/src/features/currency/application/currency_controller.dart';

import '../../helpers/test_app.dart';

void main() {
  late AppDatabase db;
  final now = DateTime.utc(2026, 11, 21, 9);

  setUp(() {
    db = openTestDatabase();
    addTearDown(() => BaseCurrency.code = 'KES');
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(() => now),
        deviceRegionProvider.overrideWithValue('KE'),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> saveRates() => DriftAppSettingsRepository(db).writeJson(
    CurrencyController.ratesKey,
    ExchangeRates.fromJson({
      'base': 'USD',
      'rates': {'KES': 129.2, 'EUR': 0.92},
    }, fetchedAt: now)!.toJson(),
  );

  test('setup saves a second currency with the main one', () async {
    final c = container();
    await c
        .read(currencyControllerProvider.notifier)
        .choose('KES', secondary: 'USD');
    expect(
      await DriftAppSettingsRepository(db)
          .readJson(CurrencyController.settingsKey),
      {
        'base': 'KES',
        'chosen': true,
        'secondary': 'USD',
        'ownRates': <String, Object?>{},
      },
    );
    final fresh = container();
    expect(
      (await fresh.read(currencyControllerProvider.future)).secondary,
      'USD',
    );
  });

  test('none is the default, and the main currency is never the second', () {
    expect(CurrencyController.settingsFrom(null).secondary, isNull);
    expect(
      CurrencyController.settingsFrom({'base': 'KES', 'secondary': 'KES'})
          .secondary,
      isNull,
    );
    expect(
      CurrencyController.settingsFrom({'base': 'KES', 'secondary': 'XYZ'})
          .secondary,
      isNull,
    );
  });

  test('it can be changed and cleared, and counting in it clears it', () async {
    await saveRates();
    final c = container();
    final notifier = c.read(currencyControllerProvider.notifier);
    await notifier.choose('KES', secondary: 'USD');
    await notifier.setSecondary('EUR');
    expect(c.read(currencyControllerProvider).value!.secondary, 'EUR');
    await notifier.setOwnRate('USD', 0.0078);
    expect(c.read(currencyControllerProvider).value!.secondary, 'EUR');
    await notifier.setSecondary(null);
    expect(c.read(currencyControllerProvider).value!.secondary, isNull);

    await notifier.setSecondary('EUR');
    expect(await notifier.switchTo('EUR'), isTrue);
    final after = c.read(currencyControllerProvider).value!;
    expect(after.base, 'EUR');
    expect(after.secondary, isNull);
  });

  test(
    'converts at the day rate when there is one, and not otherwise',
    () async {
      final none = CurrencyController.settingsFrom({
        'base': 'KES',
        'secondary': 'USD',
      });
      expect(none.inSecondary(129200, now), isNull);

      await saveRates();
      final c = container();
      await c
          .read(currencyControllerProvider.notifier)
          .choose('KES', secondary: 'USD');
      final settings = c.read(currencyControllerProvider).value!;
      // KES 1,292.00 at 129.2 to the dollar.
      final usd = settings.inSecondary(129200, now)!;
      expect(usd.currency, 'USD');
      expect(usd.minorUnits, 1000);
      expect(settings.withSecondary(null).inSecondary(129200, now), isNull);
    },
  );

  test(
    'setup saves the choice even when the saved settings cannot be read',
    () async {
      final failing = _Unreadable(DriftAppSettingsRepository(db));
      final c = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          appSettingsRepositoryProvider.overrideWithValue(failing),
          deviceRegionProvider.overrideWithValue('KE'),
        ],
      );
      addTearDown(c.dispose);
      c.listen(currencyControllerProvider, (_, _) {});
      await c.read(currencyControllerProvider.notifier).choose('UGX');
      expect(c.read(currencyControllerProvider).value!.base, 'UGX');
      expect(
        await DriftAppSettingsRepository(db)
            .readJson(CurrencyController.settingsKey),
        containsPair('base', 'UGX'),
      );
    },
  );
}

class _Unreadable implements AppSettingsRepository {
  _Unreadable(this._inner);

  final AppSettingsRepository _inner;

  @override
  Future<Map<String, Object?>?> readJson(String key) async =>
      throw StateError('The settings could not be read');

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) =>
      _inner.writeJson(key, value);
}
