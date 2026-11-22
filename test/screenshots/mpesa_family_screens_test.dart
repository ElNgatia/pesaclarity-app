// The M-Pesa family of accounts (decision 0026), for the accessibility
// check (tool/accessibility.sh): My accounts with M-Pesa closed and opened,
// What you own and owe, Ziidi's and M-Shwari's pages and Activity, each at
// every text size, in light, dark and high contrast. Not marketing
// screenshots, so tool/screenshots.sh skips them. Made-up records
// (mpesa_family_records.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/time/clock.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/features/accounts/presentation/my_accounts_settings_screen.dart';
import 'package:pesaclarity/src/features/activity/presentation/activity_screen.dart';
import 'package:pesaclarity/src/features/currency/application/currency_controller.dart';
import 'package:pesaclarity/src/features/savings/presentation/savings_account_screen.dart';
import 'package:pesaclarity/src/features/spaces/application/spaces_providers.dart';
import 'package:pesaclarity/src/features/statements/data/pdf_text_extractor.dart';
import 'package:pesaclarity/src/routing/app_shell.dart';

import '../helpers/fake_app_lock.dart';
import '../helpers/test_app.dart';
import 'harness.dart';
import 'mpesa_family_records.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget Function(FamilySeeded seeded) home,
) async {
  final db = openTestDatabase();
  final seeded = await tester.runAsync(() => FamilyRecords(db).seed());
  await tester.pumpWidget(_scope(db, home(seeded!)));
  await settleFrames(tester);
  await tester.pumpAndSettle();
}

Widget _scope(AppDatabase db, Widget home) => ProviderScope(
  overrides: [
    appDatabaseProvider.overrideWithValue(db),
    personalDatabaseProvider.overrideWithValue(db),
    clockProvider.overrideWithValue(() => familyNow),
    deviceRegionProvider.overrideWithValue('KE'),
    activeSpaceProvider.overrideWithValue(Space.personal),
    pdfTextExtractorProvider.overrideWithValue(null),
    ...appLockOverrides(),
  ],
  child: shotApp(home),
);

void main() {
  if (!checkAccessibility) return;

  screenshot('mpesa-family-accounts', (tester) async {
    await _pump(tester, (_) => const MyAccountsSettingsScreen());
    await snap(tester);
  });

  screenshot('mpesa-family-accounts-open', (tester) async {
    await _pump(tester, (_) => const MyAccountsSettingsScreen());
    final toggle = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('mpesa-family-toggle'),
    );
    await tester.scrollUntilVisible(
      toggle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await snap(tester);
  });

  screenshot('mpesa-family-own-and-owe', (tester) async {
    await _pump(tester, (_) => const MyAccountsSettingsScreen());
    await tester.tap(find.byKey(const Key('own-and-owe')));
    await tester.pumpAndSettle();
    await snap(tester);
  });

  screenshot('mpesa-family-ziidi', (tester) async {
    await _pump(tester, (s) => SavingsAccountScreen(accountId: s.ziidi));
    await snap(tester);
  });

  screenshot('mpesa-family-mshwari', (tester) async {
    await _pump(tester, (s) => SavingsAccountScreen(accountId: s.mshwari));
    await snap(tester);
  });

  screenshot('mpesa-family-activity', (tester) async {
    await _pump(
      tester,
      (_) => tabShell(const ActivityScreen(), tabs: personalTabs, index: 1),
    );
    await snap(tester);
  });
}
