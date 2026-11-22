import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/habits/check_in_reminder.dart';
import 'package:pesaclarity/src/domain/habits/habit_settings.dart';
import 'package:pesaclarity/src/domain/habits/no_spend_days.dart';
import 'package:pesaclarity/src/domain/habits/week_check_in.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_entry.dart';
import 'package:pesaclarity/src/domain/reminders/reminder_schedule.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';
import 'package:pesaclarity/src/features/habits/presentation/habits_text.dart';

import '../fixtures.dart';

final _today = CalendarDate(2026, 11, 22);
const _eatingOut = 1;
const _transport = 2;
const _rent = 9;

void main() {
  String money(int minor) => '${minor ~/ 100}';
  const names = {
    _eatingOut: 'Eating out',
    _transport: 'Transport',
    _rent: 'Rent',
  };

  List<LedgerEntry> history() => [
    // Four usual weeks of 1,500 on transport.
    for (var w = 1; w <= 4; w++)
      entry(
        at: eat(2026, 11, 16 - 7 * w + 1),
        amount: kes(1500),
        categoryId: _transport,
      ),
    // Last week: 5,000 eating out.
    entry(at: eat(2026, 11, 10), amount: kes(5000), categoryId: _eatingOut),
    // This week: 900 eating out, 3,400 transport, and rent from Plan.
    entry(at: eat(2026, 11, 17), amount: kes(900), categoryId: _eatingOut),
    entry(at: eat(2026, 11, 18), amount: kes(3400), categoryId: _transport),
    entry(at: eat(2026, 11, 19), amount: kes(25000), categoryId: _rent),
  ];

  WeekCheckIn checkIn(List<LedgerEntry> entries) => WeekCheckIn.of(
    entries,
    today: _today,
    noSpend: NoSpendDays.of(
      entries,
      today: _today,
      historyFrom: CalendarDate(2026, 10, 1),
      scheduledCategoryIds: {_rent},
    ),
    scheduledCategoryIds: {_rent},
  );

  test('three plain lines on the week', () {
    final week = checkIn(history());
    expect(week.start, CalendarDate(2026, 11, 16));
    expect(week.spentMinor, kes(4300));
    // Last week: 5,000 eating out and 1,500 transport.
    expect(week.lastWeekMinor, kes(6500));
    expect(
      HabitsText.changed(week, money, names),
      'You spent 2200 less than last week, most of it on eating out.',
    );
    expect(week.noSpendDays, 4);
    // The week before had six.
    expect(week.noSpendBestThisMonth, isFalse);
    expect(HabitsText.wentWellLine(week, money, names), 'Four no-spend days.');
    expect(week.aboveUsual!.categoryId, _transport);
    expect(
      HabitsText.nextWeekLine(week, money, names),
      'Transport is 1900 above its usual week. Try keeping it to 1500.',
    );
    expect(HabitsText.weekRange(week.start, week.end), 'Mon 16 to Sun 22 Nov');
  });

  test('a quiet week says so plainly', () {
    final week = checkIn(const []);
    expect(
      HabitsText.changed(week, money, names),
      'No spending this week or the same days of last week.',
    );
    expect(
      HabitsText.nextWeekLine(week, money, names),
      'Nothing is far above its usual week. Keep the same pace.',
    );
  });

  test('the check-in day is Sunday', () {
    expect(isCheckInDay(_today), isTrue);
    expect(isCheckInDay(_today.addDays(-1)), isFalse);
  });

  group('settings and the notification', () {
    test('read back what they wrote', () {
      const off = HabitSettings(noSpendOnHome: false, notifyMinuteOfDay: null);
      final read = HabitSettings.fromJson(off.toJson());
      expect(read.noSpendOnHome, isFalse);
      expect(read.sundayCheckIn, isTrue);
      expect(read.notifyMinuteOfDay, isNull);
      expect(HabitSettings.fromJson(null).notifyMinuteOfDay, 18 * 60);
      expect(
        HabitSettings.fromJson({'notifyMinuteOfDay': 7}).notifyMinuteOfDay,
        18 * 60,
      );
      expect(notifyLabel(18 * 60), 'Sunday at 18:00');
      expect(notifyLabel(null), 'Off');
    });

    test('comes on Sunday at 18:00 with nothing private', () {
      // Wednesday 18 November, noon.
      final reminder = checkInReminder(
        now: DateTime(2026, 11, 18, 12),
        settings: const HabitSettings(),
      )!;
      expect(reminder.at, DateTime(2026, 11, 22, 18).toUtc());
      expect(reminder.title, 'Your week in three lines is ready');
      expect(reminder.body, 'Open Pesa Clarity to read it.');
      expect(reminder.body, isNot(contains(RegExp(r'\d'))));
    });

    test('after the time on Sunday, waits for the next Sunday', () {
      final reminder = checkInReminder(
        now: DateTime(2026, 11, 22, 19),
        settings: const HabitSettings(),
      )!;
      expect(reminder.at, DateTime(2026, 11, 29, 18).toUtc());
    });

    test('none while the check-in or its notification is off', () {
      final now = DateTime(2026, 11, 18);
      expect(
        checkInReminder(
          now: now,
          settings: const HabitSettings(sundayCheckIn: false),
        ),
        isNull,
      );
      expect(
        checkInReminder(
          now: now,
          settings: const HabitSettings(notifyMinuteOfDay: null),
        ),
        isNull,
      );
    });
  });
  test('the check-in id clashes with no other reminder', () {
    expect(checkInReminderId, isNot(collectReminderId));
    expect(checkInReminderId, isNot(taxReminderId));
    for (final category in [0, 1, 99999, 100000, 123456]) {
      expect(checkInReminderId, isNot(budgetAlertReminderId(category)));
    }
  });
}
