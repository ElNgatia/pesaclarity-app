import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money/exchange_rates.dart';
import '../../../core/money/money.dart';
import '../../../core/time/clock.dart';
import '../../../data/repositories/app_settings_repository.dart';
import '../../../data/repositories/currency_rebase_repository.dart';
import '../../../data/repositories/rate_history_repository.dart';
import '../../../domain/time/calendar.dart';
import '../data/rates_client.dart';

/// The phone's region, such as `KE`, from its language settings.
final deviceRegionProvider = Provider<String?>(
  (ref) => PlatformDispatcher.instance.locale.countryCode,
);

/// How long setup waits for the saved currency settings before it saves
/// the choice over the defaults.
const choiceWait = Duration(seconds: 2);

/// How long fetched rates stay fresh.
const ratesMaxAge = Duration(hours: 12);

@immutable
class CurrencySettings {
  const CurrencySettings({
    required this.base,
    this.chosen = false,
    this.secondary,
    this.ownRates = const {},
    this.rates,
    this.history,
  });

  /// The currency the person counts in.
  final String base;

  /// Whether the person picked [base], rather than it coming from the
  /// phone's region.
  final bool chosen;

  /// A second currency the person likes to see beside [base], such as USD
  /// under the KES figure on Home; null for none. Never the same as [base].
  final String? secondary;

  /// Rates the person set: one [base] unit buys that much of a currency.
  final Map<String, double> ownRates;

  /// The latest fetched rates, in whatever base the service used.
  final ExchangeRates? rates;

  /// The first rates fetched each day, so amounts convert at their day's.
  final RateHistory? history;

  CurrencyConverter get converter => CurrencyConverter(
    base: base,
    rates: rates,
    ownRates: ownRates,
    history: history,
  );

  /// [baseMinor] base units in the [secondary] currency at the rate for
  /// [when]: the person's own rate, else that day's, else the latest. Null
  /// without a second currency or a rate for it.
  Money? inSecondary(int baseMinor, DateTime when) {
    final code = secondary;
    if (code == null) return null;
    final rate = converter.rateOn(code, when);
    if (rate == null) return null;
    return Money(
      convertMinor(baseMinor, from: base, to: code, rate: rate.rate),
      currency: code,
    );
  }

  /// A copy with [secondary] set to [code]; null for none, and so is a
  /// [code] equal to [base].
  CurrencySettings withSecondary(String? code) => CurrencySettings(
    base: base,
    chosen: chosen,
    secondary: code == base ? null : code,
    ownRates: ownRates,
    rates: rates,
    history: history,
  );

  CurrencySettings copyWith({
    String? base,
    bool? chosen,
    Map<String, double>? ownRates,
    ExchangeRates? rates,
    RateHistory? history,
  }) {
    final nextBase = base ?? this.base;
    return CurrencySettings(
      base: nextBase,
      chosen: chosen ?? this.chosen,
      // Counting in the second currency leaves no second one.
      secondary: secondary == nextBase ? null : secondary,
      ownRates: ownRates ?? this.ownRates,
      rates: rates ?? this.rates,
      history: history ?? this.history,
    );
  }

  Map<String, Object?> toJson() => {
    'base': base,
    'chosen': chosen,
    'secondary': ?secondary,
    'ownRates': ownRates,
  };
}

/// The base currency, the person's own rates and the latest fetched rates.
class CurrencyController extends AsyncNotifier<CurrencySettings> {
  static const settingsKey = 'currency.settings';
  static const ratesKey = 'currency.rates';

  AppSettingsRepository get _settings =>
      ref.read(appSettingsRepositoryProvider);

  RateHistoryRepository get _history => ref.read(rateHistoryRepositoryProvider);

  @override
  Future<CurrencySettings> build() async {
    final json = await _settings.readJson(settingsKey);
    final saved = await _settings.readJson(ratesKey);
    final rates = saved == null ? null : ExchangeRates.fromSaved(saved);
    var history = await _history.read();
    // Rates fetched before rates were kept by day become their day's.
    if (history.isEmpty && rates != null) {
      await _history.keep(CalendarDate.local(rates.fetchedAt), rates);
      history = await _history.read();
    }
    return settingsFrom(json, rates: rates, history: history);
  }

  /// The settings saved as [json] (null before any are), with [rates] and
  /// [history].
  static CurrencySettings settingsFrom(
    Map<String, Object?>? json, {
    ExchangeRates? rates,
    RateHistory? history,
  }) {
    final base = json?['base'];
    final secondary = json?['secondary'];
    final own = json?['ownRates'];
    // Amounts saved before a currency was chosen are in KES, so that stays
    // the base until the person picks one; setup suggests their region's.
    final code = base is String && isKnownCurrency(base)
        ? base
        : BaseCurrency.code;
    return CurrencySettings(
      base: code,
      chosen: json?['chosen'] == true,
      secondary:
          secondary is String && isKnownCurrency(secondary) && secondary != code
          ? secondary
          : null,
      ownRates: {
        if (own is Map)
          for (final MapEntry(:key, :value) in own.entries)
            if (key is String && value is num && value > 0)
              key: value.toDouble(),
      },
      rates: rates,
      history: history,
    );
  }

  Future<CurrencySettings> _current() async => state.value ?? await future;

  Future<void> _save(CurrencySettings next) async {
    await _settings.writeJson(settingsKey, next.toJson());
    state = AsyncData(next);
  }

  /// Saves [code] as chosen during setup, when nothing is counted yet, with
  /// [secondary] (null for none) as the second currency.
  ///
  /// It waits at most [choiceWait] for the saved settings: on a new phone
  /// there are none, so when they are slow or cannot be read it starts from
  /// the defaults and only the write has to work. A failed write throws, and
  /// nothing changes.
  Future<void> choose(String code, {String? secondary}) async {
    var current = state.value;
    var stillLoading = false;
    if (current == null) {
      try {
        current = await future.timeout(choiceWait);
      } on TimeoutException {
        stillLoading = true;
      } on Object {
        // Unreadable: the defaults, as on a new phone.
      }
    }
    final from = current ?? settingsFrom(null);
    final next = CurrencySettings(
      base: code,
      chosen: true,
      secondary: secondary == code ? null : secondary,
      ownRates: _rebaseOwn(from, code),
      rates: from.rates,
      history: from.history,
    );
    await _settings.writeJson(settingsKey, next.toJson());
    if (stillLoading) {
      // The read still under way would bring back what was there before:
      // read again, which finds what was just saved.
      ref.invalidateSelf();
    } else {
      state = AsyncData(next);
    }
  }

  /// Sets the second currency, or clears it with null.
  Future<void> setSecondary(String? code) async {
    final current = await _current();
    await _save(current.withSecondary(code));
  }

  /// Switches the base currency, converting the plan, goals, debts, loans
  /// and subscriptions typed in the old one at today's rate. Returns false,
  /// changing nothing, when there is no rate between the two.
  Future<bool> switchTo(String code) async {
    final current = await _current();
    if (code == current.base) return true;
    final rate = current.converter.rateFor(code);
    if (rate == null) return false;
    await ref
        .read(currencyRebaseRepositoryProvider)
        .rebase(from: current.base, to: code, rate: rate);
    await _save(
      CurrencySettings(
        base: code,
        chosen: true,
        // Counting in the second currency leaves no second one.
        secondary: current.secondary == code ? null : current.secondary,
        ownRates: _rebaseOwn(current, code),
        rates: current.rates,
        history: current.history,
      ),
    );
    return true;
  }

  /// Sets the person's own rate for [code] (one base unit buys [rate]), or
  /// clears it with null.
  Future<void> setOwnRate(String code, double? rate) async {
    final current = await _current();
    await _save(
      CurrencySettings(
        base: current.base,
        chosen: current.chosen,
        secondary: current.secondary,
        ownRates: {
          for (final e in current.ownRates.entries)
            if (e.key != code) e.key: e.value,
          if (rate != null && rate > 0) code: rate,
        },
        rates: current.rates,
        history: current.history,
      ),
    );
  }

  /// Fetches rates when they are older than [ratesMaxAge], or always with
  /// [force]. Returns whether rates are fresh afterwards; a failed fetch
  /// keeps the last rates.
  Future<bool> refreshRates({bool force = false}) async {
    final current = await _current();
    final now = ref.read(clockProvider)();
    final fetched = current.rates?.fetchedAt;
    if (!force && fetched != null && now.difference(fetched) < ratesMaxAge) {
      return true;
    }
    try {
      final rates = await ref.read(ratesClientProvider).fetch(current.base);
      if (rates == null) return false;
      await _settings.writeJson(ratesKey, rates.toJson());
      await _history.keep(CalendarDate.local(rates.fetchedAt), rates);
      final history = await _history.read();
      final latest = await _current();
      state = AsyncData(latest.copyWith(rates: rates, history: history));
      return true;
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Rates did not load: $error');
      return false;
    }
  }

  /// Own rates moved to a new base: a rate to the new base itself is
  /// dropped, and the rest are expressed per new base unit.
  static Map<String, double> _rebaseOwn(CurrencySettings s, String to) {
    final toRate = s.converter.rateFor(to);
    if (toRate == null) return const {};
    return {
      for (final e in s.ownRates.entries)
        if (e.key != to) e.key: e.value / toRate,
    };
  }
}

final currencyControllerProvider =
    AsyncNotifierProvider<CurrencyController, CurrencySettings>(
      CurrencyController.new,
    );

/// The base currency. Reading it also sets [BaseCurrency.code], so amounts
/// made without a currency are in it.
final baseCurrencyProvider = Provider<String>((ref) {
  final code =
      ref.watch(currencyControllerProvider).value?.base ?? BaseCurrency.code;
  BaseCurrency.code = code;
  return code;
});

/// Converts amounts into the base currency.
final currencyConverterProvider = Provider<CurrencyConverter>((ref) {
  final base = ref.watch(baseCurrencyProvider);
  final settings = ref.watch(currencyControllerProvider).value;
  return CurrencyConverter(
    base: base,
    rates: settings?.rates,
    ownRates: settings?.ownRates ?? const {},
    history: settings?.history,
  );
});

/// Fetches rates once the settings are read, when they are stale. The app
/// shell keeps it alive.
final ratesRefreshProvider = FutureProvider<bool>((ref) async {
  await ref.watch(currencyControllerProvider.future);
  if (!ref.watch(ratesConfiguredProvider)) return false;
  return ref.read(currencyControllerProvider.notifier).refreshRates();
});
