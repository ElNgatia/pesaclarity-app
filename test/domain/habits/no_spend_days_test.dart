import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/enums.dart';
import 'package:pesaclarity/src/domain/habits/no_spend_days.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_entry.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';

import '../fixtures.dart';

/// Sunday 22 November 2026.
final _today = CalendarDate(2026, 11, 22);

LedgerEntry _named({
  required DateTime at,
  required int amount,
  String? payee,
  int? categoryId,
  int accountId = 1,
  int? transferPairId,
  CategoryType? categoryType,
}) => LedgerEntry(
  id: at.microsecondsSinceEpoch ~/ 1000 + amount,
  accountId: accountId,
  occurredAt: at,
  amountMinor: amount,
  direction: TransactionDirection.outflow,
  kind: TransactionKind.paybill,
  currency: 'KES',
  categoryId: categoryId,
  categoryType: categoryType ?? CategoryType.expense,
  transferPairId: transferPairId,
  payeeName: payee,
);

void main() {
  // Mon 1,240; Tue none; Wed 380; Thu 2,100; Fri a KPLC bill and a move to
  // Chumz; Sat none; today something.
  List<LedgerEntry> week() => [
    entry(at: eat(2026, 11, 16), amount: kes(1240), categoryId: 1),
    entry(at: eat(2026, 11, 18), amount: kes(380), categoryId: 1),
    entry(at: eat(2026, 11, 19), amount: kes(2100), categoryId: 2),
    _named(
      at: eat(2026, 11, 20),
      amount: kes(1800),
      payee: 'KPLC',
      categoryId: 9,
    ),
    _named(
      at: eat(2026, 11, 20, 13),
      amount: kes(2000),
      payee: 'Chumz',
      transferPairId: 77,
    ),
    entry(at: eat(2026, 11, 22, 9), amount: kes(500), categoryId: 1),
  ];

  NoSpendDays days(List<LedgerEntry> entries, {CalendarDate? from}) =>
      NoSpendDays.of(
        entries,
        today: _today,
        historyFrom: from ?? CalendarDate(2026, 11, 14),
        scheduledCategoryIds: {9},
        cashAccountIds: {5},
      );

  test('bills in Plan and moves between own accounts do not break a day', () {
    final result = days(week());
    final byDay = {for (final d in result.week) d.date.weekday: d};
    expect(byDay[1]!.spentMinor, kes(1240));
    expect(byDay[2]!.isNoSpend, isTrue);
    expect(byDay[5]!.isNoSpend, isTrue);
    expect(byDay[5]!.leftOut.map((l) => (l.kind, l.name)), [
      (LeftOutKind.bill, 'KPLC'),
      (LeftOutKind.move, 'Chumz'),
    ]);
    expect(byDay[6]!.isNoSpend, isTrue);
    // Today is not over, so it is not counted.
    expect(byDay[7]!.counted, isFalse);
    expect(result.weekCount, 3);
    expect(result.streak, 2);
    expect(result.latestWithLeftOut!.date, CalendarDate(2026, 11, 20));
  });

  test('cash under KES 100 does not break a day; more does', () {
    final small = days([
      entry(at: eat(2026, 11, 21), amount: kes(99), accountId: 5),
    ]);
    expect(small.week[5].isNoSpend, isTrue);
    expect(small.week[5].leftOut.single.kind, LeftOutKind.smallCash);
    final big = days([
      entry(at: eat(2026, 11, 21), amount: kes(100), accountId: 5),
    ]);
    expect(big.week[5].isNoSpend, isFalse);
    // The same amount from M-Pesa is spending.
    final mpesa = days([entry(at: eat(2026, 11, 21), amount: kes(50))]);
    expect(mpesa.week[5].isNoSpend, isFalse);
  });

  test('days before the records start are not no-spend days', () {
    final result = days(const [], from: CalendarDate(2026, 11, 19));
    expect(result.weekCount, 3, reason: 'Thursday to Saturday');
    expect(result.streak, 3);
    expect(result.monthCount, 3);
  });

  test('the longest run and the count this month', () {
    final result = days([
      entry(at: eat(2026, 11, 5), amount: kes(100)),
      entry(at: eat(2026, 11, 10), amount: kes(100)),
    ], from: CalendarDate(2026, 11, 1));
    // 1 to 4, 6 to 9, 11 to 21: eleven in a row.
    expect(result.longestThisMonth, 11);
    expect(result.monthCount, 19);
    expect(result.streak, 11);
    expect(result.weekIsBestThisMonth, isTrue);
  });

  test('a week with fewer no-spend days than an earlier one is not best', () {
    final result = days([
      entry(at: eat(2026, 11, 16), amount: kes(100)),
      entry(at: eat(2026, 11, 17), amount: kes(100)),
      entry(at: eat(2026, 11, 18), amount: kes(100)),
    ], from: CalendarDate(2026, 11, 1));
    expect(result.weekCount, 3);
    expect(result.weekIsBestThisMonth, isFalse);
  });
}
