import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/budget/budget_alerts.dart';
import 'package:pesaclarity/src/domain/enums.dart';
import 'package:pesaclarity/src/domain/plan/month_plan.dart';
import 'package:pesaclarity/src/domain/plan/plan_inputs.dart';
import 'package:pesaclarity/src/domain/reminders/reminder_settings.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';

import '../fixtures.dart';

const food = 1;
const transport = 2;
const rent = 3;

const categories = [
  PlanCategory(id: food, type: CategoryType.expense, isDailySpending: true),
  PlanCategory(
    id: transport,
    type: CategoryType.expense,
    isDailySpending: true,
  ),
  PlanCategory(id: rent, type: CategoryType.expense),
];

const names = {food: 'Food', transport: 'Transport', rent: 'Rent'};

RecurringBill monthly(int id, String name, int category, int shillings) =>
    RecurringBill(
      id: id,
      name: name,
      categoryId: category,
      amountMinor: kes(shillings),
      frequency: RecurrenceFrequency.monthly,
      startDate: CalendarDate(2026, 1, 1),
    );

final november = YearMonth(2026, 11);

/// Sunday 22 November 2026.
final today = CalendarDate(2026, 11, 22);

MonthReview review({int food = 0, int transport = 0, int rent = 0}) {
  final plan = MonthPlan.build(
    month: november,
    recurring: [
      monthly(1, 'Food', _food, 10000),
      monthly(2, 'Transport', _transport, 6000),
      monthly(3, 'Rent', _rent, 25000),
    ],
    items: const [],
    categories: categories,
  );
  return MonthReview.of(plan, [
    if (food > 0)
      entry(at: eat(2026, 11, 10), amount: kes(food), categoryId: _food),
    if (transport > 0)
      entry(
        at: eat(2026, 11, 10),
        amount: kes(transport),
        categoryId: _transport,
      ),
    if (rent > 0)
      entry(at: eat(2026, 11, 1), amount: kes(rent), categoryId: _rent),
  ]);
}

const _food = food;
const _transport = transport;
const _rent = rent;

List<BudgetAlert> alertsFor(
  MonthReview r, {
  ReminderSettings settings = const ReminderSettings(),
}) => budgetAlertsIn(r, settings: settings, today: today, names: names);

void main() {
  test('at 80% a day-to-day category is nearing its plan', () {
    final alerts = alertsFor(review(food: 8000, transport: 3100));
    expect(alerts, hasLength(1));
    final alert = alerts.single;
    expect(alert.name, 'Food');
    expect(alert.level, BudgetAlertLevel.nearing);
    expect(alert.daysLeft, 9);
    expect(alert.perDayMinor, kes(220));
    expect(budgetAlertTitle(alert), 'Food has used 80% of its plan');
    expect(
      budgetAlertBody(alert, showAmounts: false),
      '9 days left this month. Open Pesa Clarity to see it.',
    );
    expect(
      budgetAlertBody(alert, showAmounts: true),
      'Food: KES 8,000 of 10,000 used, 9 days left. About 220 a day keeps it '
      'in plan.',
    );
  });

  test('over its plan, and amounts kept off the lock screen', () {
    final alert = alertsFor(review(food: 10250)).single;
    expect(alert.level, BudgetAlertLevel.over);
    expect(budgetAlertTitle(alert), 'Food is over its plan');
    expect(
      budgetAlertBody(alert, showAmounts: false),
      'Open Pesa Clarity to see by how much.',
    );
    expect(
      budgetAlertBody(alert, showAmounts: true),
      'Food: KES 10,250 of 10,000 used, 250 over. 9 days left.',
    );
  });

  test('bills such as rent never alert, even paid in full', () {
    expect(alertsFor(review(rent: 25000)), isEmpty);
  });

  test('a category share of its own, or off, wins over the share for all', () {
    final r = review(food: 7000, transport: 5000);
    expect(alertsFor(r), [
      isA<BudgetAlert>().having((a) => a.name, 'name', 'Transport'),
    ]);
    final own = const ReminderSettings().withCategoryPercent(food, 70);
    final both = alertsFor(r, settings: own);
    expect(both.map((a) => a.name), ['Transport', 'Food']);
    expect(both.last.ownShare, isTrue);
    expect(both.last.percent, 70);

    final off = const ReminderSettings().withCategoryPercent(
      transport,
      ReminderSettings.budgetAlertOff,
    );
    expect(alertsFor(r, settings: off), isEmpty);
  });

  test('a share over 100 waits for it', () {
    const settings = ReminderSettings(budgetAlertPercent: 120);
    expect(alertsFor(review(food: 11000), settings: settings), isEmpty);
    final alert = alertsFor(review(food: 12500), settings: settings).single;
    expect(alert.level, BudgetAlertLevel.over);
  });

  test('none while budget alerts are off, or in another month', () {
    expect(
      alertsFor(
        review(food: 9000),
        settings: const ReminderSettings(budgetAlerts: false),
      ),
      isEmpty,
    );
    expect(
      budgetAlertsIn(
        review(food: 9000),
        settings: const ReminderSettings(),
        today: CalendarDate(2026, 12, 1),
        names: names,
      ),
      isEmpty,
    );
  });

  group('sending', () {
    const settings = ReminderSettings();

    ({List<BudgetAlert> send, SentBudgetAlerts sent}) step(
      MonthReview r,
      SentBudgetAlerts sent, {
      ReminderSettings settings = settings,
    }) => budgetAlertsToSend(
      alerts: alertsFor(r, settings: settings),
      sent: SentBudgetAlerts.fromJson(sent.toJson()),
      settings: settings,
      month: november,
    );

    test('once at the share, once more when over, then nothing', () {
      var result = step(review(food: 8000), const SentBudgetAlerts(null, {}));
      expect(result.send.map((a) => a.level), [BudgetAlertLevel.nearing]);
      result = step(review(food: 9000), result.sent);
      expect(result.send, isEmpty);
      result = step(review(food: 10250), result.sent);
      expect(result.send.map((a) => a.level), [BudgetAlertLevel.over]);
      result = step(review(food: 12000), result.sent);
      expect(result.send, isEmpty);
    });

    test('without "Again when over", only the first', () {
      const quiet = ReminderSettings(budgetAlertAgainWhenOver: false);
      var result = step(
        review(food: 8000),
        const SentBudgetAlerts(null, {}),
        settings: quiet,
      );
      expect(result.send, hasLength(1));
      result = step(review(food: 10250), result.sent, settings: quiet);
      expect(result.send, isEmpty);
    });

    test('a new month starts afresh', () {
      final old = SentBudgetAlerts(YearMonth(2026, 10), const {
        food: BudgetAlertLevel.over,
      });
      expect(step(review(food: 8000), old).send, hasLength(1));
    });

    test('reads back what it saved, and ignores rubbish', () {
      final sent = SentBudgetAlerts(november, const {
        food: BudgetAlertLevel.nearing,
      });
      final back = SentBudgetAlerts.fromJson(sent.toJson());
      expect(back.month, november);
      expect(back.levels, {food: BudgetAlertLevel.nearing});
      expect(SentBudgetAlerts.fromJson({'month': 'x'}).month, isNull);
      expect(SentBudgetAlerts.fromJson(null).levels, isEmpty);
    });
  });

  test('settings keep budget alert choices through a save', () {
    final settings = const ReminderSettings(
      budgetAlertPercent: 65,
      budgetAlertAmountsOnLockScreen: true,
    ).withCategoryPercent(food, 70).withCategoryPercent(transport, 0);
    final back = ReminderSettings.fromJson(settings.toJson());
    expect(back, settings);
    expect(back.budgetAlertPercentFor(food), 70);
    expect(back.watchesCategory(transport), isFalse);
    expect(
      back.withCategoryPercent(food, null).budgetAlertPercentFor(food),
      65,
    );

    const defaults = ReminderSettings();
    expect(defaults.budgetAlerts, isTrue);
    expect(defaults.budgetAlertPercent, 80);
    expect(defaults.budgetAlertAgainWhenOver, isTrue);
    expect(defaults.budgetAlertAmountsOnLockScreen, isFalse);
    expect(
      ReminderSettings.fromJson({'budgetAlertPercent': 151}).budgetAlertPercent,
      80,
    );
    expect(
      ReminderSettings.fromJson({'budgetAlertPercent': 150}).budgetAlertPercent,
      150,
    );
  });
}
