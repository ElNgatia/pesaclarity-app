import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/goals/goals_aside.dart';
import '../../balances/application/balances_providers.dart';
import '../../goals/application/goals_aside_providers.dart';

/// The goals kept aside that spending has dipped into since the free money
/// ran out, for Home's gentle card. Empty while nothing is kept aside.
///
/// A dip the person answered stays quiet until it grows; once the free
/// money covers the goals again, the answer is forgotten, so the next dip
/// is asked about afresh.
final goalDipsProvider = FutureProvider<List<GoalDip>>((ref) async {
  final goals = await ref.watch(goalsAsideProvider.future);
  if (goals.isEmpty) return const [];
  final onHand = await ref.watch(onHandProvider.future);
  if (onHand == null) return const [];
  final dips = goals.dips(onHand.beforeGoalsMinor);
  final dipped = {for (final d in dips) d.goal.id};
  final controller = ref.read(keptAsideProvider.notifier);
  for (final MapEntry(key: id, value: kept) in goals.settings.byGoal.entries) {
    if (kept.seenDipMinor > 0 && !dipped.contains(id)) {
      // Not awaited: forgetting it reloads this provider.
      unawaited(Future.microtask(() => controller.dipOver(id)));
    }
  }
  return dips;
});
