import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money/money.dart';
import '../../../core/time/clock.dart';
import '../../../data/database/database_providers.dart';
import '../../../data/repositories/app_settings_repository.dart';
import '../../../data/repositories/categories_repository.dart';
import '../../../data/repositories/goals_repository.dart';
import '../../../data/repositories/journal_repository.dart';
import '../../../data/repositories/plan_repository.dart';
import '../../../data/repositories/transactions_repository.dart';
import '../../../domain/about_you/about_you.dart';
import '../../../domain/enums.dart';
import '../../../domain/plan/month_plan.dart';
import '../../../domain/plan/plan_inputs.dart';
import '../../../domain/spaces/space.dart';
import '../../../domain/time/calendar.dart';
import '../../plan/application/plan_providers.dart';

/// The answers to About you. They are about the person, not a space, so
/// they are kept with Personal's settings whichever space is open, and
/// never leave the phone.
class AboutYouController extends AsyncNotifier<AboutYou> {
  static const settingsKey = 'aboutYou';

  @override
  Future<AboutYou> build() async => AboutYou.fromJson(
    await ref.watch(mainSettingsRepositoryProvider).readJson(settingsKey),
  );

  /// Saves [next]; a failed write throws and changes nothing.
  Future<void> save(AboutYou next) async {
    await ref
        .read(mainSettingsRepositoryProvider)
        .writeJson(settingsKey, next.toJson());
    state = AsyncData(next);
  }

  Future<void> _change(AboutYou Function(AboutYou) change) async =>
      save(change(await future));

  /// Setup offered the questions on [day]: Home offers them once more from
  /// the next day. Only the first offer counts.
  Future<void> noteOffered(CalendarDate day) =>
      _change((a) => a.offeredOn == null ? a.copyWith(offeredOn: day) : a);

  /// Home's offer was taken or closed; from then on only Profile has it.
  Future<void> closeHomeOffer() =>
      _change((a) => a.copyWith(homeOfferClosed: true));

  /// Goals' suggestion was added or put off.
  Future<void> closeGoalOffer() =>
      _change((a) => a.copyWith(goalOfferClosed: true));
}

final aboutYouProvider = AsyncNotifierProvider<AboutYouController, AboutYou>(
  AboutYouController.new,
);

/// What the last three months of messages show was paid, in the base
/// currency.
class RecentSpending {
  const RecentSpending({required this.byKey, required this.spendingMinor});

  /// Paid towards each seeded category, by its key, over three months.
  final Map<String, int> byKey;

  /// Day-to-day and bill spending over three months: expense categories and
  /// uncategorised spending, without savings, debt or tax.
  final int spendingMinor;

  /// An average month of [spendingMinor].
  int get monthSpendingMinor => (spendingMinor / 3).round();
}

/// One whole unit of the base currency in minor units, such as 100 for KES.
int get baseUnitMinor {
  var unit = 1;
  for (var i = 0; i < minorUnitDigits(BaseCurrency.code); i++) {
    unit *= 10;
  }
  return unit;
}

/// What the open space paid over the last three months, by category, read
/// as Plan reads a month's actuals.
final recentSpendingProvider = FutureProvider<RecentSpending>((ref) async {
  ref.watch(ledgerChangesProvider);
  final now = ref.watch(clockProvider)();
  final today = CalendarDate.local(now);
  final from = CalendarDate(today.year, today.month - 3, today.day);
  final categories = await ref
      .watch(categoriesRepositoryProvider)
      .watchAll()
      .first;
  final planCategories = [
    for (final c in categories)
      PlanCategory(
        id: c.id,
        type: c.type,
        isDailySpending: c.isDailySpending,
        key: c.key,
      ),
  ];
  final entries = await ref
      .watch(transactionsRepositoryProvider)
      .ledgerEntries(from: from.startInstant, to: now);
  final journal = await readJournal(ref);
  final byId = <int?, int>{};
  for (
    var month = from.yearMonth;
    month.compareTo(today.yearMonth) <= 0;
    month = month.next
  ) {
    final review = MonthReview.of(
      MonthPlan.build(
        month: month,
        recurring: const [],
        items: const [],
        categories: planCategories,
      ),
      entries,
      journal: journal,
    );
    for (final c in review.categories) {
      byId[c.categoryId] = (byId[c.categoryId] ?? 0) + c.actualMinor;
    }
  }
  final keys = {for (final c in categories) c.id: c};
  var spending = 0;
  final byKey = <String, int>{};
  for (final MapEntry(key: id, value: paid) in byId.entries) {
    final category = keys[id];
    if (category?.key case final key?) byKey[key] = (byKey[key] ?? 0) + paid;
    if (id == null || category?.type == CategoryType.expense) {
      spending += paid;
    }
  }
  return RecentSpending(byKey: byKey, spendingMinor: spending);
});

/// Starts Plan with the categories picked in [answers], each at what the
/// last three months show it costs. Categories Plan already has this month
/// are left as they are. Returns how many were added.
Future<int> startPlanFrom(WidgetRef ref, AboutYou answers) async {
  if (answers.pays.isEmpty) return 0;
  final spent = await ref.read(recentSpendingProvider.future);
  final starts = planStartFor(answers.pays, spent.byKey, unit: baseUnitMinor);
  if (starts.isEmpty) return 0;
  final repository = ref.read(planRepositoryProvider);
  final month = ref.read(currentMonthProvider);
  final plan = await repository.monthPlan(month);
  final planned = {for (final l in plan.lines) l.categoryId};
  final categories = ref.read(categoriesRepositoryProvider);
  var added = 0;
  for (final start in starts) {
    final category = await categories.byKey(start.categoryKey);
    if (category == null || planned.contains(category.id)) continue;
    await repository.saveRecurring(
      name: start.payment.label,
      categoryId: category.id,
      amountMinor: start.amountMinor,
      frequency: RecurrenceFrequency.monthly,
      startDate: CalendarDate(month.year, month.month, 1),
    );
    planned.add(category.id);
    added++;
  }
  if (added > 0) ref.invalidate(planViewProvider);
  return added;
}

/// The one goal Goals suggests from About you, until a goal is added or
/// it is put off; null when there is none to show. Personal only.
final aboutYouGoalProvider = FutureProvider.autoDispose<GoalSuggestion?>((
  ref,
) async {
  if (ref.watch(activeSpaceIdProvider) != personalSpaceId) return null;
  final answers = await ref.watch(aboutYouProvider.future);
  if (!answers.answered || answers.goalOfferClosed) return null;
  final goals = await ref.watch(goalsRepositoryProvider).goals();
  if (goals.isNotEmpty) return null;
  final spent = await ref.watch(recentSpendingProvider.future);
  return goalSuggestionFor(
    answers,
    spent.monthSpendingMinor,
    unit: baseUnitMinor,
  );
});
