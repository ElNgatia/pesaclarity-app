import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/budget/safe_to_spend.dart';
import 'package:pesaclarity/src/domain/goals/goals_aside.dart';
import 'package:pesaclarity/src/domain/goals/savings_goal.dart';
import 'package:pesaclarity/src/domain/ledger/on_hand.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';

import '../fixtures.dart';

void main() {
  final schoolFees = SavingsGoal(
    id: 1,
    name: 'School fees',
    targetMinor: kes(45000),
    savedMinor: kes(20000),
    targetDate: CalendarDate(2027, 1, 31),
  );
  final laptop = SavingsGoal(
    id: 2,
    name: 'New laptop',
    targetMinor: kes(60000),
    savedMinor: kes(4000),
  );
  final chumz = SavingsGoal(
    id: 3,
    name: 'Christmas',
    targetMinor: kes(10000),
    savedMinor: kes(5000),
    backing: const GoalBacking(
      accountId: 9,
      accountName: 'Chumz',
      pocketId: 4,
      pocketName: 'Christmas',
    ),
  );
  final dollars = SavingsGoal(
    id: 4,
    name: 'Trip',
    targetMinor: 100000,
    savedMinor: 50000,
    currency: 'USD',
  );

  group('kept aside settings', () {
    test('read back what they wrote, and ignore what they do not know', () {
      final settings = const KeptAsideSettings()
          .withKept(1, kept: true)
          .withGoal(1, (k) => k.copyWith(gapMinor: kes(1500)))
          .withKept(2, kept: true);
      final read = KeptAsideSettings.fromJson(settings.toJson());
      expect(read.isKept(1), isTrue);
      expect(read.byGoal[1]!.gapMinor, kes(1500));
      expect(read.isKept(2), isTrue);
      expect(read.isKept(3), isFalse);
      expect(KeptAsideSettings.fromJson(null).byGoal, isEmpty);
      expect(
        KeptAsideSettings.fromJson({
          'goals': {
            'x': {'gap': 1},
            '5': {'gap': -4, 'seenDip': 'a'},
          },
        }).byGoal.keys,
        [5],
      );
      expect(KeptAsideSettings.fromJson({'goals': 'no'}).byGoal, isEmpty);
    });

    test('turning a goal off forgets it; turning it on starts afresh', () {
      final settings = const KeptAsideSettings()
          .withKept(1, kept: true)
          .withGoal(1, (k) => k.copyWith(gapMinor: 10, seenDipMinor: 20));
      expect(settings.withKept(1, kept: false).isKept(1), isFalse);
      final again = settings.withKept(1, kept: false).withKept(1, kept: true);
      expect(again.byGoal[1]!.gapMinor, 0);
      expect(again.byGoal[1]!.seenDipMinor, 0);
      // A goal not kept is left alone.
      expect(settings.withGoal(7, (k) => k).isKept(7), isFalse);
    });
  });

  group('goals aside', () {
    final settings = const KeptAsideSettings()
        .withKept(1, kept: true)
        .withKept(2, kept: true)
        .withKept(3, kept: true)
        .withKept(4, kept: true);

    test('only goals typed by the person, in the base currency, count', () {
      final aside = GoalsAside.of(
        [schoolFees, laptop, chumz, dollars],
        settings,
        currency: 'KES',
      );
      expect(
        [for (final g in aside.goals) g.goal.name],
        ['School fees', 'New laptop'],
      );
      expect(aside.totalMinor, kes(24000));
      expect(canKeepAside(chumz, baseCurrency: 'KES'), isFalse);
      expect(canKeepAside(dollars, baseCurrency: 'KES'), isFalse);
      expect(canKeepAside(schoolFees, baseCurrency: 'KES'), isTrue);
    });

    test('a goal left as it is after a dip keeps less aside', () {
      final aside = GoalsAside.of(
        [schoolFees],
        settings.withGoal(1, (k) => k.copyWith(gapMinor: kes(1500))),
        currency: 'KES',
      );
      expect(aside.totalMinor, kes(18500));
    });

    test('a dip comes out of the last goal first', () {
      final aside = GoalsAside.of(
        [schoolFees, laptop],
        settings,
        currency: 'KES',
      );
      // 24,000 kept; the accounts less the fund hold 18,500.
      expect(aside.stillAsideMinor(kes(18500)), kes(18500));
      final dips = aside.dips(kes(18500));
      expect(
        [for (final d in dips) (d.goal.name, d.dipMinor)],
        [('School fees', kes(1500)), ('New laptop', kes(4000))],
      );
      expect(dips.first.stillAsideMinor, kes(18500));
      expect(aside.dips(kes(30000)), isEmpty);
      // Below zero, everything kept is dipped into.
      expect(aside.stillAsideMinor(-kes(100)), 0);
      expect(
        aside.dips(-kes(100)).fold(0, (sum, d) => sum + d.dipMinor),
        kes(24000),
      );
    });

    test('a dip the person answered is seen until it grows', () {
      final answered = settings.withGoal(
        1,
        (k) => k.copyWith(seenDipMinor: kes(1500)),
      );
      final aside = GoalsAside.of([schoolFees], answered, currency: 'KES');
      expect(aside.dips(kes(18500)).single.seen, isTrue);
      expect(aside.dips(kes(18000)).single.seen, isFalse);
    });
  });

  group('On hand', () {
    OnHand onHand(int accounts, {int goals = 0}) => OnHand(
      byAccount: {1: accounts},
      rainyDayMinor: kes(5000),
      fulizaOwedMinor: 0,
      goalsWantedMinor: goals,
    );

    test('takes the goals kept aside off, as the rainy day fund', () {
      // M-Pesa 33,069 + Equity 12,000 less 5,000 less 20,000.
      final hand = OnHand(
        byAccount: {1: kes(33069), 2: kes(12000)},
        rainyDayMinor: kes(5000),
        fulizaOwedMinor: 0,
        goalsWantedMinor: kes(20000),
      );
      expect(hand.goalsAsideMinor, kes(20000));
      expect(hand.totalMinor, kes(20069));
      expect(hand.goalsDippedMinor, 0);
    });

    test('shows zero, not below, when spending dips into a goal', () {
      final hand = onHand(kes(23500), goals: kes(20000));
      expect(hand.totalMinor, 0);
      expect(hand.goalsAsideMinor, kes(18500));
      expect(hand.goalsDippedMinor, kes(1500));
    });

    test('is still below zero when the accounts are', () {
      final hand = onHand(kes(4000), goals: kes(20000));
      expect(hand.goalsAsideMinor, 0);
      expect(hand.totalMinor, -kes(1000));
    });

    test('without goals, is as before', () {
      expect(onHand(kes(45069)).totalMinor, kes(40069));
    });
  });

  group('Safe to spend with goals kept aside', () {
    final today = CalendarDate(2026, 11, 22);

    test('the days ahead share no more than the free money', () {
      final plain = SafeToSpend.calculate(
        budgetMinor: kes(60000),
        entries: const [],
        today: today,
        onHandMinor: kes(5000),
      );
      final kept = SafeToSpend.calculate(
        budgetMinor: kes(60000),
        entries: const [],
        today: today,
        onHandMinor: kes(5000),
        goalsKeptMinor: kes(20000),
      );
      expect(kept.leftTodayMinor, lessThan(plain.leftTodayMinor));
      // Nine days are left, Sunday 22 to Monday 30 November.
      expect(
        kept.weekdayLimitMinor * 7 + kept.weekendLimitMinor * 2,
        lessThanOrEqualTo(kes(5000)),
      );
      expect(kept.nothingFreeAfterGoals, isFalse);
    });

    test('is zero once the free money is used up, without a warning', () {
      final used = SafeToSpend.calculate(
        budgetMinor: kes(60000),
        entries: const [],
        today: today,
        onHandMinor: 0,
        goalsKeptMinor: kes(20000),
      );
      expect(used.leftTodayMinor, 0);
      expect(used.nothingFreeAfterGoals, isTrue);
    });
  });
}
