import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/time/clock.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/domain/insights/insights_summary.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';
import 'package:pesaclarity/src/features/insights/application/insights_providers.dart';
import 'package:pesaclarity/src/features/insights/application/tag_totals_provider.dart';

import '../../domain/fixtures.dart';
import '../../helpers/test_app.dart';

// Sunday 22 November 2026, 10:00 EAT.
final _now = DateTime.utc(2026, 11, 22, 7);

/// A person's ledger as Home and Activity show it: this month and the
/// months before, some categorised by hand, an income-only month, a
/// statement import and an own transfer. No scan mark: nothing here came
/// from a first scan.
Future<({int tag, int lounge})> _seed(AppDatabase db) async {
  Future<int> account(String name, AccountType type) => db
      .into(db.accounts)
      .insert(
        AccountsCompanion.insert(
          name: name,
          type: type,
          openingDate: DateTime.utc(2026),
        ),
      );
  final mpesa = await account('M-Pesa', AccountType.mpesa);
  final bank = await account('Bank', AccountType.bank);
  final food = await db
      .into(db.categories)
      .insert(
        CategoriesCompanion.insert(
          name: 'Test food',
          type: CategoryType.expense,
        ),
      );
  final salary = await db
      .into(db.categories)
      .insert(
        CategoriesCompanion.insert(
          name: 'Test salary',
          type: CategoryType.income,
        ),
      );
  final lounge = await db
      .into(db.payees)
      .insert(
        PayeesCompanion.insert(
          displayName: 'Example Lounge',
          leakType: const Value(LeakType.lifestyle),
        ),
      );

  Future<int> add(
    DateTime at,
    int shillings, {
    int? accountId,
    TransactionDirection direction = TransactionDirection.outflow,
    TransactionKind kind = TransactionKind.till,
    int? categoryId,
    int? payeeId,
    TransactionSource source = TransactionSource.sms,
  }) => db
      .into(db.transactions)
      .insert(
        TransactionsCompanion.insert(
          accountId: accountId ?? mpesa,
          occurredAt: at,
          amountMinor: kes(shillings),
          direction: direction,
          kind: Value(kind),
          payeeId: Value(payeeId),
          categoryOverrideId: Value(categoryId),
          source: source,
        ),
      );

  // November: spending, one categorised by hand, one at a lounge.
  await add(eat(2026, 11, 3), 1500, categoryId: food);
  final atLounge = await add(eat(2026, 11, 8), 4000, payeeId: lounge);
  await add(eat(2026, 11, 20), 700);
  // October: salary and spending.
  await add(
    eat(2026, 10, 1),
    50000,
    direction: TransactionDirection.inflow,
    kind: TransactionKind.received,
    categoryId: salary,
  );
  await add(eat(2026, 10, 15), 8000, categoryId: food);
  // September: money in only.
  await add(
    eat(2026, 9, 1),
    50000,
    direction: TransactionDirection.inflow,
    kind: TransactionKind.received,
    categoryId: salary,
  );
  // August: from a bank statement.
  await add(
    eat(2026, 8, 12),
    3000,
    accountId: bank,
    source: TransactionSource.statement,
  );
  // July: an own transfer, M-Pesa to the bank, and nothing else.
  final out = await add(eat(2026, 7, 5), 2000, kind: TransactionKind.sent);
  final into = await add(
    eat(2026, 7, 5),
    2000,
    accountId: bank,
    direction: TransactionDirection.inflow,
    kind: TransactionKind.received,
  );
  await (db.update(db.transactions)..where((t) => t.id.equals(out))).write(
    TransactionsCompanion(transferPairId: Value(into)),
  );
  await (db.update(db.transactions)..where((t) => t.id.equals(into))).write(
    TransactionsCompanion(transferPairId: Value(out)),
  );

  final tag = await db
      .into(db.tags)
      .insert(TagsCompanion.insert(name: 'roadtrip'));
  await db
      .into(db.transactionTags)
      .insert(
        TransactionTagsCompanion.insert(transactionId: atLounge, tagId: tag),
      );
  return (tag: tag, lounge: atLounge);
}

ProviderContainer _container(AppDatabase db) {
  final c = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => _now),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// Lets the database's change notices reach the providers.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late AppDatabase db;

  setUp(() => db = openTestDatabase());

  test('every month with transactions counts, whatever they are', () async {
    await _seed(db);
    final c = _container(db);
    final summary = await c.read(insightsSummaryProvider.future);

    expect(summary.hasData, isTrue);
    expect(summary.current.month, YearMonth(2026, 11));
    expect(
      {for (final m in summary.trend) m.month.month: m.entryCount},
      {
        6: 0,
        7: 2, // an own transfer
        8: 1, // a statement import
        9: 1, // money in only
        10: 2,
        11: 3,
      },
    );
    expect(summary.current.spendingMinor, kes(6200));
    expect(summary.current.leakage.lifestyleMinor, kes(4000));
    expect(summary.previous!.incomeMinor, kes(50000));
  });

  test(
    'Insights opened before anything was read fills once transactions come',
    () async {
      final c = _container(db);
      // The tab is opened first, on an empty ledger, and stays open.
      c.listen(insightsSummaryProvider, (_, _) {});
      c.listen(spendingChartProvider, (_, _) {});
      c.listen(findingsProvider, (_, _) {});
      c.listen(tagTotalsThisMonthProvider, (_, _) {});
      expect((await c.read(insightsSummaryProvider.future)).hasData, isFalse);
      expect(await c.read(tagTotalsThisMonthProvider.future), isEmpty);

      // Then accounts are chosen and messages read, and some sorted by
      // hand, as Home and Activity show at once.
      final seeded = await _seed(db);
      expect(seeded.lounge, isPositive);
      await _settle();

      final summary = await c.read(insightsSummaryProvider.future);
      expect(summary.hasData, isTrue);
      expect(summary.current.entryCount, 3);
      expect(summary.current.leakageMinor, kes(4000));
      expect(
        (await c.read(spendingChartProvider.future)).totalMinor,
        kes(6200),
      );
      expect(await c.read(findingsProvider.future), isNotEmpty);
      final tags = await c.read(tagTotalsThisMonthProvider.future);
      expect(tags[seeded.tag]!.totals.spendingMinor, kes(4000));
    },
  );

  test('a transaction in a currency without a rate still counts', () {
    final summary = InsightsSummary.of([
      entry(at: eat(2026, 11, 3), amount: 1000, currency: 'USD'),
    ], month: YearMonth(2026, 11));
    expect(summary.hasData, isTrue);
    expect(summary.current.entryCount, 1);
    // Its amount is left out of totals in shillings.
    expect(summary.current.spendingMinor, 0);
  });

  test('with no transactions at all, there is nothing to show', () async {
    final c = _container(db);
    expect((await c.read(insightsSummaryProvider.future)).hasData, isFalse);
  });
}
