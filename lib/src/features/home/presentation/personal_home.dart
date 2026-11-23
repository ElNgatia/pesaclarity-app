import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../domain/home/home_period.dart';
import '../../../domain/ledger/activity_feed.dart';
import '../../../domain/time/calendar.dart';
import '../../../routing/app_routes.dart';
import '../../../shared/widgets/amounts_hidden.dart';
import '../../../shared/widgets/figures.dart';
import '../../../theme/app_typography.dart';
import '../../../theme/layout.dart';
import '../../../theme/pesa_colors.dart';
import '../../activity/presentation/add_transaction_sheet.dart';
import '../../balances/presentation/balance_text.dart';
import '../../balances/presentation/balance_warning.dart';
import '../../insights/presentation/spending_charts_card.dart';
import '../../plan/presentation/budget_alert_cards.dart';
import '../../settings/application/week_start_provider.dart';
import '../../support/presentation/support_card.dart';
import '../application/home_period_providers.dart';
import '../application/home_safe_provider.dart';
import '../application/things_to_sort_provider.dart';
import '../application/upcoming_bills_provider.dart';
import 'home_cards.dart';

/// Text sizes from which Home's three figures stack, label then amount,
/// so none is cut.
const _stackFromScale = 1.3;

/// Home for a personal space, top to bottom: the period's tabs, money in
/// and out with the fees in it, safe to spend today, the way to the rest
/// of this month, real problems on their own, one row for things to sort,
/// what is coming up and charts (closed). Transactions day by day are
/// Activity's, not Home's.
class PersonalHome extends ConsumerWidget {
  const PersonalHome({required this.today, super.key});

  final CalendarDate today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Loads the week's first day for every week Home and the app count.
    ref.watch(weekStartControllerProvider);
    final period = ref.watch(homePeriodProvider);
    final view = ref.watch(homePeriodViewProvider(period)).value;
    final things = ref.watch(thingsToSortProvider);
    final over = ref.watch(overBudgetAlertsProvider);
    final bills = ref.watch(upcomingBillsProvider).value ?? const [];
    final isNew = view != null && !view.hasRecords;

    void swipe(DragEndDetails details) {
      final v = details.primaryVelocity ?? 0;
      if (v.abs() < 200) return;
      final i = period.index + (v < 0 ? 1 : -1);
      if (i < 0 || i >= HomePeriod.values.length) return;
      ref.read(homePeriodProvider.notifier).select(HomePeriod.values[i]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PeriodTabs(
          selected: period,
          onSelect: (p) => ref.read(homePeriodProvider.notifier).select(p),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          key: const Key('home-period-swipe'),
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: swipe,
          child: _InOutCard(view: view),
        ),
        const SizedBox(height: Layout.cardGap),
        // Thanks a gift as its message comes in; the card that asks is in
        // Things to sort.
        SupportHomeCard(
          moneyTight: ref.watch(homeMoneyTightProvider),
          thanksOnly: true,
        ),
        const _SafeToday(),
        const BalanceWarningLine(),
        const SizedBox(height: Layout.cardGap),
        // Real problems, each on its own.
        const WhatWasThisCard(),
        for (final alert in over)
          BudgetAlertCard(
            alert,
            key: Key('home-over-${alert.categoryId}'),
            inPlan: false,
            onTap: () => context.go(AppRoutes.plan),
          ),
        if (things.isNotEmpty) ...[
          _RowCard(
            key: const Key('home-things-to-sort'),
            title: 'Things to sort (${things.length})',
            subtitle: sortSummary(things),
            dot: things.any((t) => t.group == SortGroup.needsYou),
            onTap: () => context.push(AppRoutes.thingsToSort),
          ),
          const SizedBox(height: Layout.cardGap),
        ],
        if (isNew)
          const _NewUserCard()
        else
          _RowCard(
            key: const Key('home-more-month'),
            title: 'More about this month',
            subtitle: 'Until next money, runway, forecast, financial health',
            onTap: () => context.push(AppRoutes.moreThisMonth),
          ),
        HomeComingUp(bills: bills, today: today),
        if (!isNew) ...[const SizedBox(height: 20), const _ChartsCard()],
      ],
    );
  }
}

/// This week, Last week, This month, Last month: the chosen one in red
/// text, with no fill or line under it. Scrolls sideways when they do not
/// fit, as with large text.
class _PeriodTabs extends StatelessWidget {
  const _PeriodTabs({required this.selected, required this.onSelect});

  final HomePeriod selected;
  final ValueChanged<HomePeriod> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    return SingleChildScrollView(
      key: const Key('home-periods'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final p in HomePeriod.values)
            Semantics(
              selected: p == selected,
              button: true,
              child: InkWell(
                key: Key('home-period-${p.name}'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => onSelect(p),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Center(
                      widthFactor: 1,
                      child: Text(
                        p.label,
                        style: theme.textTheme.titleSmall!.copyWith(
                          color: p == selected ? colors.link : colors.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Money in, Money out and Difference for the period, then the fees in
/// Money out. Opens the period in Activity.
class _InOutCard extends StatelessWidget {
  const _InOutCard({required this.view});

  final HomePeriodView? view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final sums = view?.sums ?? const InOut();
    final label = theme.textTheme.bodySmall!.copyWith(color: colors.textMuted);
    final stack = MediaQuery.textScalerOf(context).scale(1) >= _stackFromScale;
    final figures = [
      ('Money in', sums.inMinor, colors.successText, ActivityType.moneyIn),
      ('Money out', sums.outMinor, onSurface, ActivityType.spending),
      ('Difference', sums.differenceMinor, onSurface, ActivityType.all),
    ];
    Widget figure(int minor, Color color) => FigureText(
      shownMoney(context, minor),
      style: AppTypography.tileFigure(color),
    );
    final span = view?.span;
    // Each figure opens Activity for the period, for its direction.
    Widget open(String name, ActivityType type, Widget child) => InkWell(
      key: Key('home-figure-${type.name}'),
      borderRadius: BorderRadius.circular(8),
      onTap: span == null
          ? null
          : () => context.go(
              AppRoutes.activityWith(
                ActivityFilter(type: type, from: span.first, to: span.last),
              ),
            ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: child,
      ),
    );
    return Card(
      key: const Key('home-in-out'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (stack)
              for (final (name, minor, color, type) in figures)
                open(
                  name,
                  type,
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(child: Text(name, style: label)),
                      const SizedBox(width: 12),
                      Flexible(child: figure(minor, color)),
                    ],
                  ),
                )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, (name, minor, color, type))
                      in figures.indexed) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: open(
                        name,
                        type,
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name, style: label),
                            figure(minor, color),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            if (sums.feesMinor != 0) ...[
              const SizedBox(height: 10),
              Text(
                'of which fees ${shownMoney(context, sums.feesMinor, withCurrency: true)}',
                key: const Key('home-fees'),
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Safe to spend today as a plain row: today's amount, and about how much
/// a day for how many days under it. Red only below zero. Opens More
/// about this month, where what it is made of is.
class _SafeToday extends ConsumerWidget {
  const _SafeToday();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    final safe = ref.watch(homeSafeProvider);
    final monthly = safe.monthly;
    final untilNext = safe.untilNext;
    final int amount;
    final String line;
    final bool below;
    String plain(int minor) => shownMoney(context, minor, withCurrency: true);
    // About: whole shillings, never cents.
    String about(int daily, int days) =>
        'About ${plain(daily ~/ 100 * 100)} a day for '
        '${days == 1 ? '1 day' : '$days days'}';
    if (untilNext != null) {
      below = untilNext.belowZero;
      amount = below ? untilNext.onHandMinor : untilNext.leftTodayMinor;
      line = below
          ? (untilNext.fulizaOwedMinor > 0
                ? BalanceText.belowZeroFuliza
                : BalanceText.belowZero)
          : about(untilNext.dailyMinor, untilNext.days);
    } else if (monthly != null) {
      final onHand = monthly.onHandMinor;
      below = onHand != null && onHand < 0;
      amount = below ? onHand : monthly.leftTodayMinor;
      final days = monthly.weekdaysLeft + monthly.weekendDaysLeft;
      final left = monthly.leftThisMonthMinor;
      line = below
          ? BalanceText.belowZero
          : left <= 0
          ? "This month's day-to-day budget is used up"
          : about(days <= 0 ? left : left ~/ days, days <= 0 ? 1 : days);
    } else {
      return Card(
        key: const Key('home-safe'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Safe to spend today', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Shows once your messages have been read and Plan has a '
                'budget.',
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      key: const Key('home-safe'),
      child: ListTile(
        title: const Text('Safe to spend today'),
        subtitle: Text(line),
        trailing: Text(
          plain(amount),
          style: AppTypography.rowAmount(
            below ? theme.colorScheme.error : theme.colorScheme.onSurface,
          ),
        ),
        onTap: () => context.push(AppRoutes.moreThisMonth),
      ),
    );
  }
}

/// A plain card with a title, a line under it and a chevron; with [dot],
/// the amber dot of something that needs the person.
class _RowCard extends StatelessWidget {
  const _RowCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.dot = false,
    super.key,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final colors = PesaColors.of(context);
    return Card(
      child: ListTile(
        leading: dot
            ? Icon(Icons.circle, size: 10, color: colors.warning)
            : null,
        minLeadingWidth: 10,
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Icon(Icons.chevron_right, color: colors.textMuted),
        onTap: onTap,
      ),
    );
  }
}

/// Nothing read yet: how to start, with reading messages as
/// the main button and adding one by hand under it.
class _NewUserCard extends StatelessWidget {
  const _NewUserCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('home-new-user'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Shows once this space has transactions. Read your M-Pesa '
              'messages, or add one by hand.',
              style: theme.textTheme.bodyMedium!.copyWith(
                color: PesaColors.of(context).textMuted,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('home-read-messages'),
              onPressed: () => context.go(AppRoutes.myAccounts),
              child: const Text('Read my messages'),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('home-add-by-hand'),
              onPressed: () => showAddTransactionSheet(context),
              child: const Text('Add by hand'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Charts: in and out by week and the top categories, as Insights draws
/// them. Always starts closed.
class _ChartsCard extends StatefulWidget {
  const _ChartsCard();

  @override
  State<_ChartsCard> createState() => _ChartsCardState();
}

class _ChartsCardState extends State<_ChartsCard> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = PesaColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: ListTile(
            key: const Key('home-charts'),
            leading: const Icon(Icons.bar_chart),
            title: const Text('Charts'),
            subtitle: const Text('In and out by week, top categories'),
            trailing: Icon(
              _open ? Icons.expand_less : Icons.expand_more,
              color: colors.textMuted,
            ),
            onTap: () => setState(() => _open = !_open),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: Layout.cardGap),
          const SpendingChartsSection(),
        ],
      ],
    );
  }
}
