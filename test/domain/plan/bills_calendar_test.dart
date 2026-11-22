import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/debts/debt.dart';
import 'package:pesaclarity/src/domain/debts/next_due.dart';
import 'package:pesaclarity/src/domain/enums.dart';
import 'package:pesaclarity/src/domain/plan/bills_calendar.dart';
import 'package:pesaclarity/src/domain/plan/month_plan.dart';
import 'package:pesaclarity/src/domain/plan/plan_inputs.dart';
import 'package:pesaclarity/src/domain/subscriptions/subscriptions.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';

import '../fixtures.dart';

const salary = 1;
const school = 2;
const food = 3;
const utilities = 4;

const categories = [
  PlanCategory(id: salary, type: CategoryType.income),
  PlanCategory(id: school, type: CategoryType.expense),
  PlanCategory(id: food, type: CategoryType.expense, isDailySpending: true),
  PlanCategory(id: utilities, type: CategoryType.expense),
];

RecurringBill monthly(
  int id,
  String name,
  int category,
  int kesAmount,
  int day,
) => RecurringBill(
  id: id,
  name: name,
  categoryId: category,
  amountMinor: kes(kesAmount),
  frequency: RecurrenceFrequency.monthly,
  startDate: CalendarDate(2026, 1, day),
);

final november = YearMonth(2026, 11);

/// Sunday 22 November 2026.
final today = CalendarDate(2026, 11, 22);

BillsMonth calendar({
  List<SubscriptionLine> subscriptions = const [],
  List<Debt> debts = const [],
}) {
  final plan = MonthPlan.build(
    month: november,
    recurring: [
      monthly(1, 'Salary', salary, 100000, 25),
      monthly(2, 'School fees', school, 15000, 25),
      monthly(3, 'Food', food, 10000, 1),
      monthly(4, 'Water bill', utilities, 1200, 18),
      monthly(5, 'Power', utilities, 2000, 2),
    ],
    items: const [],
    categories: categories,
  );
  return BillsMonth.of(
    review: MonthReview.of(plan, [
      entry(at: eat(2026, 11, 2), amount: kes(2000), categoryId: utilities),
    ]),
    today: today,
    categoryNames: const {school: 'School', utilities: 'Utilities'},
    subscriptions: subscriptions,
    debts: debts,
  );
}

void main() {
  test('Plan bills by due date: no income, no day-to-day budgets', () {
    final month = calendar();
    expect(month.byDay.keys.toSet(), {
      CalendarDate(2026, 11, 25),
      CalendarDate(2026, 11, 18),
      CalendarDate(2026, 11, 2),
    });
    final fees = month.on(CalendarDate(2026, 11, 25)).single;
    expect(fees.name, 'School fees');
    expect(fees.detail, 'Plan · School');
    expect(fees.state, CalendarBillState.unpaid);
    expect(fees.line, isNotNull);

    expect(
      month.on(CalendarDate(2026, 11, 18)).single.state,
      CalendarBillState.late,
    );
    expect(month.stillDueOn(CalendarDate(2026, 11, 18)), isTrue);
    expect(month.stillDueOn(CalendarDate(2026, 11, 2)), isFalse);
    expect(month.stillDueOn(CalendarDate(2026, 11, 3)), isNull);
  });

  test('tracked subscriptions show when charged and when next due', () {
    final internet = Subscription(
      id: 1,
      name: 'Home internet',
      amountMinor: kes(2999),
      frequency: RecurrenceFrequency.monthly,
      nextDate: CalendarDate(2026, 11, 25),
    );
    final water = Subscription(
      id: 2,
      name: 'water bill',
      amountMinor: kes(1200),
      frequency: RecurrenceFrequency.monthly,
      nextDate: CalendarDate(2026, 11, 28),
    );
    final month = calendar(
      subscriptions: [
        SubscriptionLine(
          subscription: internet,
          amountMinor: kes(2999),
          nextDate: CalendarDate(2026, 11, 25),
          lastChargedOn: CalendarDate(2026, 10, 25),
        ),
        // The same name as a Plan bill: it shows once, from Plan.
        SubscriptionLine(
          subscription: water,
          amountMinor: kes(1200),
          nextDate: CalendarDate(2026, 11, 28),
        ),
      ],
    );
    final day = month.on(CalendarDate(2026, 11, 25));
    expect(day.map((b) => (b.name, b.detail)), [
      ('School fees', 'Plan · School'),
      ('Home internet', 'Subscription · every month'),
    ]);
    expect(month.on(CalendarDate(2026, 11, 28)), isEmpty);
  });

  test('loan instalments: paid with the day, or still due', () {
    final bank = Debt(
      id: 1,
      lender: 'Bank loan',
      type: DebtType.bankLoan,
      balanceMinor: kes(40000),
      minimumPaymentMinor: kes(8000),
      nextDue: NextDue(date: CalendarDate(2026, 12, 5)),
      lastPayment: (date: CalendarDate(2026, 11, 5), amountMinor: kes(8000)),
    );
    final family = Debt(
      id: 2,
      lender: 'Grace Wanjiru',
      type: DebtType.family,
      balanceMinor: kes(6000),
      instalments: [
        DebtInstalment(
          dueDate: CalendarDate(2026, 11, 28),
          amountMinor: kes(3000),
        ),
      ],
      lastPayment: (date: CalendarDate(2026, 11, 6), amountMinor: kes(3000)),
    );
    final month = calendar(debts: [bank, family]);
    final paid = month.on(CalendarDate(2026, 11, 5)).single;
    expect(paid.detail, 'Debts · instalment');
    expect(paid.state, CalendarBillState.paid);
    expect(paid.paidOn, CalendarDate(2026, 11, 5));
    final next = month.on(CalendarDate(2026, 11, 28)).single;
    expect(next.detail, 'Debts · family loan');
    expect(next.state, CalendarBillState.unpaid);
    expect(
      month.on(CalendarDate(2026, 11, 6)).single.state,
      CalendarBillState.paid,
    );
  });

  test('the grid runs Monday to Sunday around the month', () {
    final days = calendarGridDays(november);
    expect(days.first, CalendarDate(2026, 10, 26));
    expect(days.last, CalendarDate(2026, 12, 6));
    expect(days.length % 7, 0);
  });
}
