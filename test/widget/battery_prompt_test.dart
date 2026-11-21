import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pesaclarity/src/core/time/clock.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/data/repositories/app_settings_repository.dart';
import 'package:pesaclarity/src/features/accounts/domain/institution.dart';
import 'package:pesaclarity/src/features/battery/application/battery_providers.dart';
import 'package:pesaclarity/src/features/battery/domain/battery_prompt.dart';
import 'package:pesaclarity/src/features/battery/presentation/battery_sheet.dart';
import 'package:pesaclarity/src/features/home/application/cash_flow_forecast_provider.dart';
import 'package:pesaclarity/src/features/home/application/health_index_provider.dart';
import 'package:pesaclarity/src/features/home/application/safe_to_spend_provider.dart';
import 'package:pesaclarity/src/features/home/application/upcoming_bills_provider.dart';
import 'package:pesaclarity/src/features/home/presentation/home_screen.dart';
import 'package:pesaclarity/src/features/income/application/income_providers.dart';
import 'package:pesaclarity/src/features/review/application/review_providers.dart';
import 'package:pesaclarity/src/features/sms/application/sms_capture_providers.dart';
import 'package:pesaclarity/src/features/sms/data/sms_source.dart';
import 'package:pesaclarity/src/routing/app_routes.dart';
import 'package:pesaclarity/src/theme/app_theme.dart';

import '../helpers/fake_battery_source.dart';
import '../helpers/fake_sms_source.dart';
import '../helpers/test_app.dart';

/// Saturday 21 November 2026, 09:00 EAT.
final _now = DateTime.utc(2026, 11, 21, 6);

const _cardTitle = 'Messages may be missed';
const _cardBody =
    "Your phone's battery saver puts Pesa Clarity to sleep, so new M-Pesa "
    'and bank messages may not show up.';

List<Override> _overrides(
  AppDatabase db,
  FakeBatterySource battery, {
  bool android = true,
  SmsSource? sms,
}) => [
  appDatabaseProvider.overrideWithValue(db),
  clockProvider.overrideWithValue(() => _now),
  batteryIsAndroidProvider.overrideWithValue(android),
  batterySourceProvider.overrideWithValue(battery),
  smsSourceProvider.overrideWithValue(sms ?? FakeSmsSource()),
  selectedInstitutionsProvider.overrideWith(
    (ref) => [ref.watch(institutionCatalogueProvider).first],
  ),
  // Home's own figures stay out of the way.
  liveSmsCaptureProvider.overrideWith((ref) => const Stream.empty()),
  pendingReviewProvider.overrideWith((ref) => Stream.value(const [])),
  safeToSpendTodayProvider.overrideWith((ref) async => null),
  untilNextMoneyProvider.overrideWith((ref) async => null),
  cashFlowForecastProvider.overrideWith((ref) async => null),
  healthIndexProvider.overrideWith((ref) async => null),
  upcomingBillsProvider.overrideWith((ref) async => []),
];

/// The app going to Settings and coming back.
Future<void> _leaveAndComeBack(WidgetTester tester) async {
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await settleFrames(tester);
}

void main() {
  for (final (name, theme) in [
    ('light', AppTheme.light),
    ('dark', AppTheme.dark),
  ]) {
    group('$name theme', () {
      late AppDatabase db;
      late FakeBatterySource battery;

      setUp(() {
        db = openTestDatabase();
        battery = FakeBatterySource();
      });

      Future<void> home(
        WidgetTester tester, {
        bool android = true,
        SmsSource? sms,
      }) async {
        final router = GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
            GoRoute(
              path: AppRoutes.chooseAccounts,
              builder: (_, _) => const Scaffold(body: Text('Choose accounts')),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: _overrides(db, battery, android: android, sms: sms),
            child: MaterialApp.router(theme: theme, routerConfig: router),
          ),
        );
        await settleFrames(tester);
      }

      testAppWidgets('Home shows the card under the lead card while '
          'restricted', (tester) async {
        await home(tester);
        expect(find.byKey(const Key('home-battery')), findsOneWidget);
        expect(find.text(_cardTitle), findsOneWidget);
        expect(find.text(_cardBody), findsOneWidget);
        expect(find.text('Fix this'), findsOneWidget);
        expect(find.text('Not now'), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(const Key('home-battery'))).dy,
          greaterThan(tester.getTopLeft(find.text('Safe to spend today')).dy),
        );
      });

      testAppWidgets('no card when not restricted, without SMS, or on '
          'iPhone', (tester) async {
        battery.restricted = false;
        await home(tester);
        expect(find.text(_cardTitle), findsNothing);

        battery.restricted = true;
        await home(tester, sms: FakeSmsSource(current: SmsAccess.denied));
        expect(find.text(_cardTitle), findsNothing);

        await home(tester, android: false, sms: const ShortcutSmsSource());
        expect(find.text(_cardTitle), findsNothing);
      });

      testAppWidgets('"Not now" hides the card and remembers when', (
        tester,
      ) async {
        await home(tester);
        await tester.tap(find.byKey(const Key('home-battery-not-now')));
        await settleFrames(tester);
        expect(find.text(_cardTitle), findsNothing);
        final saved = await tester.runAsync(
          () =>
              DriftAppSettingsRepository(db)
                  .readJson(BatteryPromptController.settingsKey),
        );
        expect(BatteryPromptState.fromJson(saved).notNowAt, _now);
      });

      testAppWidgets('"Fix this" shows Samsung\'s steps, opens Settings, and '
          'says All set once fixed', (tester) async {
        await home(tester);
        await tester.tap(find.byKey(const Key('home-battery-fix')));
        await settleFrames(tester);

        expect(find.text('Keep Pesa Clarity awake'), findsOneWidget);
        expect(
          find.text(
            'Samsung puts apps to sleep to save battery. Change these two '
            'settings so new messages are read as they arrive.',
          ),
          findsOneWidget,
        );
        expect(find.text('Let it run in the background'), findsOneWidget);
        expect(find.text('Take it off the sleeping lists'), findsOneWidget);
        expect(
          find.text(
            'Remove Pesa Clarity from Sleeping apps and from Deep sleeping '
            'apps.',
          ),
          findsOneWidget,
        );
        expect(find.text('Come back here'), findsOneWidget);
        expect(find.text('The app checks again on its own.'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is SettingsPath &&
                w.places.join(' › ') ==
                    'Settings › Apps › Pesa Clarity › Battery › Unrestricted',
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is SettingsPath &&
                w.places.join(' › ') ==
                    'Settings › Battery › Background usage limits',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            'Pesa Clarity only reads messages from the senders you chose.',
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('battery-open-settings')));
        await settleFrames(tester);
        expect(battery.settingsOpened, 1);

        // Still restricted on return: the steps stay.
        await _leaveAndComeBack(tester);
        expect(find.text('Keep Pesa Clarity awake'), findsOneWidget);

        battery.restricted = false;
        await _leaveAndComeBack(tester);
        expect(find.byKey(const Key('battery-all-set')), findsOneWidget);
        expect(find.text('All set'), findsOneWidget);
        expect(
          find.text('Pesa Clarity can now read new messages as they arrive.'),
          findsOneWidget,
        );
        expect(find.text('Read messages again'), findsOneWidget);
        expect(find.text('Picks up anything it missed'), findsOneWidget);

        await tester.tap(find.byKey(const Key('battery-done')));
        await settleFrames(tester);
        expect(find.text('All set'), findsNothing);
        expect(find.text(_cardTitle), findsNothing);
      });

      testAppWidgets('other phones get the usual path, without the sleeping '
          'lists', (tester) async {
        battery = FakeBatterySource(manufacturer: 'TECNO');
        await home(tester);
        await tester.tap(find.byKey(const Key('home-battery-fix')));
        await settleFrames(tester);
        expect(find.text('Keep Pesa Clarity awake'), findsOneWidget);
        expect(find.text('Let it run in the background'), findsOneWidget);
        expect(
          find.text('On some phones this is called "Don\'t optimise".'),
          findsOneWidget,
        );
        expect(find.text('Take it off the sleeping lists'), findsNothing);
        expect(find.textContaining('Samsung'), findsNothing);
        expect(find.text('Come back here'), findsOneWidget);
      });

      testAppWidgets('says so when Settings does not open', (tester) async {
        battery.opens = false;
        await home(tester);
        await tester.tap(find.byKey(const Key('home-battery-fix')));
        await settleFrames(tester);
        await tester.tap(find.byKey(const Key('battery-open-settings')));
        await settleFrames(tester);
        expect(find.textContaining('Settings did not open'), findsOneWidget);
      });

      testAppWidgets('"Read messages again" goes to the accounts it reads', (
        tester,
      ) async {
        await home(tester);
        await tester.tap(find.byKey(const Key('home-battery-fix')));
        await settleFrames(tester);
        battery.restricted = false;
        await _leaveAndComeBack(tester);
        await tester.tap(find.byKey(const Key('battery-read-again')));
        await settleFrames(tester);
        expect(find.text('Choose accounts'), findsOneWidget);
        expect(find.text('All set'), findsNothing);
      });
    });
  }
}
