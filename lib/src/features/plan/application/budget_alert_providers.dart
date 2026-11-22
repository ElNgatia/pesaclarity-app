import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/database/app_database.dart' show Category;
import '../../../data/repositories/app_settings_repository.dart';
import '../../../data/repositories/debts_repository.dart';
import '../../../domain/budget/budget_alerts.dart';
import '../../../domain/plan/bills_calendar.dart';
import '../../../domain/time/calendar.dart';
import '../../reminders/application/reminders_controller.dart';
import '../../subscriptions/application/subscriptions_providers.dart';
import 'plan_providers.dart';

/// Category names by id.
final planCategoryNamesProvider = Provider<Map<int, String>>(
  (ref) => {
    for (final c in ref.watch(planCategoriesProvider).value ?? <Category>[])
      c.id: c.name,
  },
);

/// This month's budget alerts, for the cards in Plan and on Home: the most
/// pressing first. Empty while budget alerts are off.
final budgetAlertsProvider = FutureProvider<List<BudgetAlert>>((ref) async {
  final settings = await ref.watch(remindersControllerProvider.future);
  if (!settings.budgetAlerts) return const [];
  final month = ref.watch(currentMonthProvider);
  final view = await ref.watch(planViewProvider(month).future);
  return budgetAlertsIn(
    view.review,
    settings: settings,
    today: CalendarDate.local(ref.watch(clockProvider)()),
    names: ref.watch(planCategoryNamesProvider),
  );
});

/// [month]'s bills by day, for the calendar in Plan.
final billsMonthProvider = FutureProvider.family<BillsMonth, YearMonth>((
  ref,
  month,
) async {
  final today = CalendarDate.local(ref.watch(clockProvider)());
  final view = await ref.watch(planViewProvider(month).future);
  final subscriptions = await ref.watch(subscriptionsOverviewProvider.future);
  final debts = await ref.watch(debtsRepositoryProvider).debts(today: today);
  return BillsMonth.of(
    review: view.review,
    today: today,
    categoryNames: ref.watch(planCategoryNamesProvider),
    subscriptions: subscriptions.lines,
    debts: debts,
  );
});

/// How Plan shows its bills.
enum BillsView { list, calendar }

/// The bills view last chosen, kept for next time.
class BillsViewController extends Notifier<BillsView> {
  static const settingKey = 'plan.billsView';

  @override
  BillsView build() {
    _load();
    return BillsView.list;
  }

  bool _chosen = false;

  Future<void> _load() async {
    try {
      final saved = await ref
          .read(appSettingsRepositoryProvider)
          .readJson(settingKey);
      final view = BillsView.values
          .where((v) => v.name == saved?['view'])
          .firstOrNull;
      if (view != null && !_chosen) state = view;
    } on Object {
      // Keep the list.
    }
  }

  Future<void> show(BillsView view) async {
    _chosen = true;
    state = view;
    await ref.read(appSettingsRepositoryProvider).writeJson(settingKey, {
      'view': view.name,
    });
  }
}

final billsViewProvider = NotifierProvider<BillsViewController, BillsView>(
  BillsViewController.new,
);

/// The day the calendar has chosen; null shows today, or the 1st in
/// another month.
class BillsDay extends Notifier<CalendarDate?> {
  @override
  CalendarDate? build() => null;

  void choose(CalendarDate? day) => state = day;
}

final billsDayProvider = NotifierProvider<BillsDay, CalendarDate?>(
  BillsDay.new,
);

/// Asks Plan to scroll to its bills, as Home's "Coming up" does when it
/// opens the calendar. Each request is a new number.
class BillsFocus extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}

final billsFocusProvider = NotifierProvider<BillsFocus, int>(BillsFocus.new);
