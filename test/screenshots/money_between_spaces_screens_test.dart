// Money between spaces (decision 0027), for the accessibility check
// (tool/accessibility.sh): Balances with the stall's part under M-Pesa,
// On hand, the stall's Money with "On your M-Pesa", Pay yourself on the
// shared line, naming a till, the till question, the repair's result
// sheet and its one question, each at every text size, in light, dark and
// high contrast. Not marketing screenshots, so tool/screenshots.sh skips
// them. Made-up records: the owner's M-Pesa holds KES 38,469, of which
// KES 650 is Vegetable stall's.
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/time/clock.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/data/repositories/app_settings_repository.dart';
import 'package:pesaclarity/src/data/repositories/money_repair.dart';
import 'package:pesaclarity/src/data/repositories/space_move_repository.dart';
import 'package:pesaclarity/src/domain/spaces/line_routing.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/features/balances/presentation/balances_screen.dart';
import 'package:pesaclarity/src/features/balances/presentation/on_hand_sheet.dart';
import 'package:pesaclarity/src/features/books/presentation/money_screen.dart';
import 'package:pesaclarity/src/features/currency/application/currency_controller.dart';
import 'package:pesaclarity/src/features/sales/presentation/records_sheets.dart';
import 'package:pesaclarity/src/features/spaces/application/routing_providers.dart';
import 'package:pesaclarity/src/features/spaces/application/spaces_providers.dart';
import 'package:pesaclarity/src/features/spaces/presentation/money_repair_sheets.dart';
import 'package:pesaclarity/src/features/spaces/presentation/shared_line_card.dart';
import 'package:pesaclarity/src/features/spaces/presentation/till_sheet.dart';
import 'package:pesaclarity/src/shared/widgets/app_sheet.dart';

import '../domain/fixtures.dart';
import '../helpers/fake_app_lock.dart';
import '../helpers/test_app.dart';
import 'harness.dart';

final _now = eat(2026, 11, 21, 9, 41);

const _stall = Space(
  id: 'stall',
  name: 'Vegetable stall',
  kind: SpaceKind.business,
);

/// Personal's M-Pesa with KES 37,819, Grace Wambui's KES 650 switched to
/// the stall, which also has its cash drawer and KCB.
Future<void> _seed(AppDatabase personal, AppDatabase business) async {
  await DriftAppSettingsRepository(personal).writeJson(
    SpacesController.settingsKey,
    spacesToJson([Space.personal, _stall]),
  );
  final mpesa = await personal
      .into(personal.accounts)
      .insert(
        AccountsCompanion.insert(
          name: 'M-Pesa',
          type: AccountType.mpesa,
          openingBalanceMinor: const Value(3781900),
          openingDate: eat(2026, 11, 1),
          institutionId: const Value('mpesa'),
        ),
      );
  for (final (name, type, minor) in [
    ('Cash', AccountType.cash, 200000),
    ('KCB', AccountType.bank, 1000000),
  ]) {
    await business
        .into(business.accounts)
        .insert(
          AccountsCompanion.insert(
            name: name,
            type: type,
            openingBalanceMinor: Value(minor),
            openingDate: eat(2026, 11, 1),
          ),
        );
  }
  final sale = await personal
      .into(personal.transactions)
      .insert(
        TransactionsCompanion.insert(
          accountId: mpesa,
          occurredAt: eat(2026, 11, 20, 17, 6),
          amountMinor: 65000,
          direction: TransactionDirection.inflow,
          kind: const Value(TransactionKind.received),
          source: TransactionSource.sms,
          counterpartyName: const Value('GRACE WAMBUI'),
          receiptNo: const Value('TKK7QX2M4P'),
          dedupeKey: const Value('TKK7QX2M4P|65000'),
          balanceAfterMinor: const Value(3846900),
        ),
      );
  await DriftSpaceMoveRepository(
    personal,
    (_) async => (business, false),
    nameOf: (id) async => id == _stall.id ? _stall.name : 'Personal',
  ).move(sale, _stall.id);
}

/// Registers [name]: [screen] (or an empty screen that opens [open]) in
/// Personal or the stall, over the seeded records.
void _shot(
  String name, {
  Widget? screen,
  void Function(BuildContext context)? open,
  bool inStall = false,
  List<Override> overrides = const [],
}) {
  screenshot(name, (tester) async {
    final personal = openTestDatabase();
    final business = openTestDatabase();
    await tester.runAsync(() async {
      await business.becomeSpace(SpaceKind.business);
      await _seed(personal, business);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(inStall ? business : personal),
          personalDatabaseProvider.overrideWithValue(personal),
          mainDatabaseProvider.overrideWithValue(personal),
          clockProvider.overrideWithValue(() => _now),
          deviceRegionProvider.overrideWithValue('KE'),
          activeSpaceProvider.overrideWithValue(
            inStall ? _stall : Space.personal,
          ),
          activeSpaceIdProvider.overrideWith(
            () => ActiveSpaceId(inStall ? _stall.id : personalSpaceId),
          ),
          ...appLockOverrides(),
          ...overrides,
        ],
        child: shotApp(
          screen ??
              Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: TextButton(
                      onPressed: () => open!(context),
                      child: const Text('Open'),
                    ),
                  ),
                ),
              ),
        ),
      ),
    );
    await settleFrames(tester);
    if (screen == null) {
      await tester.tap(find.text('Open'));
      await settleFrames(tester);
    }
    await tester.pumpAndSettle();
    await snap(tester);
  });
}

void main() {
  if (!checkAccessibility) return;

  _shot('between-balances', screen: const BalancesScreen());
  _shot('between-on-hand', open: showOnHandSheet);
  _shot('between-money', screen: const MoneyScreen(), inStall: true);
  _shot('between-pay-yourself', open: showPayYourselfSheet, inStall: true);
  _shot(
    'between-till-sheet',
    open: (c) => showTillSheet(c, line: 'mpesa'),
    inStall: true,
  );
  _shot(
    'between-till-question',
    screen: const Scaffold(body: SafeArea(child: SharedLineCard())),
    inStall: true,
    overrides: [
      sharedLineQuestionsProvider.overrideWith(
        (ref) async => [
          SharedLineQuestion(
            transactionId: 1,
            institutionId: 'mpesa',
            amountMinor: 120000,
            currency: 'KES',
            isInflow: true,
            at: _now,
            through: const ReceivedThrough(ChannelKind.till, number: '123456'),
            asksNumber: true,
          ),
        ],
      ),
    ],
  );
  _shot(
    'between-repair-result',
    open: (c) => showAppSheet<void>(
      context: c,
      builder: (_) => const RepairResultSheet(
        MoneyRepairResult(
          switched: {'stall': 23},
          removed: {
            'stall': ['M-Pesa'],
          },
          unsettled: 1,
        ),
      ),
    ),
  );
  _shot(
    'between-repair-question',
    open: (c) => showAppSheet<void>(
      context: c,
      builder: (_) => const RepairQuestionSheet(
        RepairQuestion(
          spaceId: 'stall',
          ownersAccountId: 1,
          line: 'M-Pesa',
          suggestedMinor: 65000,
        ),
      ),
    ),
  );
}
