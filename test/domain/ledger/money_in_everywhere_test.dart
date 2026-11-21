import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/enums.dart';
import 'package:pesaclarity/src/domain/income/week_by_week.dart';
import 'package:pesaclarity/src/domain/insights/findings.dart';
import 'package:pesaclarity/src/domain/insights/first_insight.dart';
import 'package:pesaclarity/src/domain/ledger/activity_feed.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_entry.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_role.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_totals.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/domain/spaces/space_summary.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';

import '../fixtures.dart';

/// Every "money in" figure is the same number: income and money from
/// people not named yet, never own transfers or borrowing. Income itself
/// (ratios, tax, profit) still waits for a name. Made-up data.
void main() {
  // A Friday.
  final today = CalendarDate(2026, 11, 20);
  final from = today.yearMonth.firstDay.startInstant;
  final to = today.addDays(1).startInstant;

  final history = <LedgerEntry>[
    // Named income: 10,000 this week, 2,000 earlier in the month.
    inflow(
      at: eat(2026, 11, 17),
      amount: kes(10000),
      payeeId: 1,
      categoryType: CategoryType.income,
    ),
    inflow(
      at: eat(2026, 11, 3),
      amount: kes(2000),
      payeeId: 1,
      categoryType: CategoryType.income,
    ),
    // Not named yet: 3,000 this week.
    inflow(at: eat(2026, 11, 18), amount: kes(3000)),
    // Fuliza and an own transfer: never money in.
    inflow(
      at: eat(2026, 11, 18),
      amount: kes(500),
      kind: TransactionKind.fulizaDraw,
    ),
    entry(
      at: eat(2026, 11, 19),
      amount: kes(4000),
      direction: TransactionDirection.inflow,
      kind: TransactionKind.bank,
      transferPairId: 999,
    ),
    entry(
      at: eat(2026, 11, 19),
      amount: kes(1000),
      categoryType: CategoryType.expense,
    ),
  ];

  const moneyIn = 15000 * 100;
  const income = 12000 * 100;

  test('LedgerTotals: money in is what arrived, income waits for a name', () {
    final totals = LedgerTotals.of(history, from: from, to: to);
    expect(totals.moneyInMinor, moneyIn);
    expect(totals.incomeMinor, income);
    expect(
      totals.moneyInMinor,
      history.where(isMoneyArrived).fold<int>(0, (s, e) => s + e.amountMinor),
    );
  });

  test("Home's In line, for spaces that show it as In", () {
    for (final kind in [
      SpaceKind.personal,
      SpaceKind.household,
      SpaceKind.other,
    ]) {
      final summary = SpaceSummary.of(
        kind,
        history,
        today: today,
        categories: const {},
        balanceMinor: 0,
      );
      expect(summary.inMinor, moneyIn, reason: kind.name);
    }
    // Shown as Rent: what was earned.
    final rental = SpaceSummary.of(
      SpaceKind.rentalProperty,
      history,
      today: today,
      categories: const {},
      balanceMinor: 0,
    );
    expect(rental.inMinor, income);
  });

  test("Activity's In this week and week by week agree", () {
    expect(weekInOut(history, today: today).inMinor, kes(13000));
    final weeks = WeekByWeek.of(history, today: today);
    expect(weeks.thisWeek.inMinor, kes(13000));
  });

  test("Insights' Money in so far", () {
    final finding = findingsFor(
      history,
      today: today,
    ).whereType<IncomeFinding>().single;
    expect(finding.nowMinor, moneyIn);
  });

  test("the first insight's Money in, and its income", () {
    final insight = FirstInsight.of(history, from: from, to: to);
    expect(insight.moneyInMinor, moneyIn);
    expect(insight.incomeMinor, income);
  });
}
