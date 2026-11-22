import '../../core/money/money.dart';
import '../../core/money/money_format.dart';
import '../enums.dart';
import '../plan/month_plan.dart';
import '../reminders/reminder_settings.dart';
import '../time/calendar.dart';

/// How far a category is through its plan.
enum BudgetAlertLevel {
  /// At or past its alert share, still within its plan.
  nearing,

  /// Past its plan.
  over,
}

/// A Plan category that has used its alert share of the plan, or more.
class BudgetAlert {
  const BudgetAlert({
    required this.categoryId,
    required this.name,
    required this.plannedMinor,
    required this.usedMinor,
    required this.daysLeft,
    required this.level,
    this.percent = ReminderSettings.defaultBudgetAlertPercent,
    this.ownShare = false,
  });

  /// The share that brought the alert.
  final int percent;

  /// Whether [percent] is the category's own, not the share for all.
  final bool ownShare;

  final int categoryId;
  final String name;
  final int plannedMinor;
  final int usedMinor;

  /// Days left in the month, today included.
  final int daysLeft;
  final BudgetAlertLevel level;

  /// The share of the plan used, in whole percent, rounded down.
  int get usedPercent =>
      plannedMinor <= 0 ? 100 : usedMinor * 100 ~/ plannedMinor;

  int get leftMinor => plannedMinor - usedMinor;

  int get overMinor => usedMinor - plannedMinor;

  /// What a day can take for the rest of the month to stay in plan: to the
  /// nearest 10 shillings from 100 shillings up. Null when over.
  int? get perDayMinor {
    if (level == BudgetAlertLevel.over || daysLeft <= 0) return null;
    final perDay = leftMinor ~/ daysLeft;
    const ten = 10 * 100;
    if (perDay < 10 * ten) return perDay - perDay % 100;
    return (perDay + ten ~/ 2) ~/ ten * ten;
  }
}

/// The categories budget alerts can watch in [plan]: day-to-day spending
/// categories, such as Food or Transport. Bills are left out: paying rent
/// in full is not overspending.
bool isBudgetCategory(MonthPlan plan, int? categoryId) {
  final category = plan.categories[categoryId];
  return category != null &&
      category.type == CategoryType.expense &&
      category.isDailySpending;
}

/// Watched categories in [review] that have used their alert share of the
/// plan on [today], the most used first. Only the month [today] is in has
/// alerts; a past or later month has none.
List<BudgetAlert> budgetAlertsIn(
  MonthReview review, {
  required ReminderSettings settings,
  required CalendarDate today,
  required Map<int, String> names,
}) {
  if (!settings.budgetAlerts || review.month != today.yearMonth) {
    return const [];
  }
  final daysLeft = review.month.dayCount - today.day + 1;
  final alerts = <BudgetAlert>[];
  for (final category in review.categories) {
    final id = category.categoryId;
    if (id == null || !isBudgetCategory(review.plan, id)) continue;
    if (!settings.watchesCategory(id)) continue;
    final planned = category.plannedMinor;
    final used = category.actualMinor;
    if (planned <= 0) continue;
    final percent = settings.budgetAlertPercentFor(id);
    final reached = used * 100 >= planned * percent;
    // A share over 100 waits for it: no alert at 100 before it.
    if (!reached && (percent > 100 || used <= planned)) continue;
    final level = used > planned
        ? BudgetAlertLevel.over
        : BudgetAlertLevel.nearing;
    alerts.add(
      BudgetAlert(
        categoryId: id,
        name: names[id] ?? 'A category',
        plannedMinor: planned,
        usedMinor: used,
        daysLeft: daysLeft,
        level: level,
        percent: percent,
        ownShare: settings.budgetAlertCategoryPercents.containsKey(id),
      ),
    );
  }
  alerts.sort((a, b) {
    final byLevel = b.level.index.compareTo(a.level.index);
    if (byLevel != 0) return byLevel;
    return (b.usedMinor * a.plannedMinor).compareTo(
      a.usedMinor * b.plannedMinor,
    );
  });
  return alerts;
}

String _plain(int minor) => formatMoney(Money(minor), withCurrency: false);

String _kes(int minor) => formatMoney(Money(minor));

String _daysLeft(int days) => days == 1 ? '1 day left' : '$days days left';

/// The alert's title, the same on the lock screen, in Plan and on Home:
/// `Food has used 80% of its plan` or `Food is over its plan`.
String budgetAlertTitle(BudgetAlert alert) => switch (alert.level) {
  BudgetAlertLevel.nearing =>
    '${alert.name} has used ${alert.usedPercent}% of its plan',
  BudgetAlertLevel.over => '${alert.name} is over its plan',
};

/// The notification's text. With [showAmounts] off it names no amount.
String budgetAlertBody(BudgetAlert alert, {required bool showAmounts}) {
  final left = _daysLeft(alert.daysLeft);
  if (!showAmounts) {
    return switch (alert.level) {
      BudgetAlertLevel.nearing =>
        '$left this month. Open Pesa Clarity to see it.',
      BudgetAlertLevel.over => 'Open Pesa Clarity to see by how much.',
    };
  }
  final used =
      '${alert.name}: ${_kes(alert.usedMinor)} of '
      '${_plain(alert.plannedMinor)} used';
  return switch (alert.level) {
    BudgetAlertLevel.nearing => switch (alert.perDayMinor) {
      final perDay? =>
        '$used, $left. About ${_plain(perDay)} a day keeps it in plan.',
      null => '$used, $left.',
    },
    BudgetAlertLevel.over => '$used, ${_plain(alert.overMinor)} over. $left.',
  };
}

/// What has been sent this month: each category's highest alert.
class SentBudgetAlerts {
  const SentBudgetAlerts(this.month, this.levels);

  /// Reads what [toJson] saved; anything else is an empty record for no
  /// month.
  factory SentBudgetAlerts.fromJson(Map<String, Object?>? json) {
    final month = json?['month'];
    final levels = json?['levels'];
    final parsed = month is int && month % 100 >= 1 && month % 100 <= 12
        ? YearMonth.fromKey(month)
        : null;
    if (parsed == null || levels is! Map<String, Object?>) {
      return const SentBudgetAlerts(null, {});
    }
    final read = <int, BudgetAlertLevel>{};
    for (final MapEntry(:key, :value) in levels.entries) {
      final id = int.tryParse(key);
      final level = BudgetAlertLevel.values
          .where((l) => l.name == value)
          .firstOrNull;
      if (id != null && level != null) read[id] = level;
    }
    return SentBudgetAlerts(parsed, read);
  }

  final YearMonth? month;
  final Map<int, BudgetAlertLevel> levels;

  Map<String, Object?> toJson() => {
    'month': ?month?.key,
    'levels': {for (final e in levels.entries) '${e.key}': e.value.name},
  };
}

/// The budget alerts to send now, and the record to keep afterwards.
///
/// Each category is alerted once at its share and, with
/// [ReminderSettings.budgetAlertAgainWhenOver], once more when it goes
/// over. A category already over when first seen gets the over alert only.
/// A category that falls back under its share, as when its plan is raised,
/// can be alerted again. The record starts afresh each month.
({List<BudgetAlert> send, SentBudgetAlerts sent}) budgetAlertsToSend({
  required List<BudgetAlert> alerts,
  required SentBudgetAlerts sent,
  required ReminderSettings settings,
  required YearMonth month,
}) {
  final before = sent.month == month
      ? sent.levels
      : const <int, BudgetAlertLevel>{};
  final after = <int, BudgetAlertLevel>{};
  final send = <BudgetAlert>[];
  for (final alert in alerts) {
    final had = before[alert.categoryId];
    after[alert.categoryId] = alert.level;
    if (had == alert.level || had == BudgetAlertLevel.over) {
      if (had == BudgetAlertLevel.over) {
        after[alert.categoryId] = BudgetAlertLevel.over;
      }
      continue;
    }
    if (alert.level == BudgetAlertLevel.over &&
        had == BudgetAlertLevel.nearing &&
        !settings.budgetAlertAgainWhenOver) {
      continue;
    }
    send.add(alert);
  }
  return (send: send, sent: SentBudgetAlerts(month, after));
}
