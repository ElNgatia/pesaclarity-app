import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/app_settings_repository.dart';
import '../../../data/repositories/goals_repository.dart';
import '../../../domain/goals/goals_aside.dart';
import '../../currency/application/currency_controller.dart';

/// Which goals are kept aside ("Keep it aside" on the goal), and what the
/// person answered after a dip. Kept in the space's settings: a note in the
/// app, never a bank lock.
class KeptAsideController extends AsyncNotifier<KeptAsideSettings> {
  static const settingsKey = 'goals.keptAside';

  @override
  Future<KeptAsideSettings> build() async => KeptAsideSettings.fromJson(
    await ref.watch(appSettingsRepositoryProvider).readJson(settingsKey),
  );

  Future<void> _save(
    KeptAsideSettings Function(KeptAsideSettings) update,
  ) async {
    final next = update(state.value ?? await future);
    await ref
        .read(appSettingsRepositoryProvider)
        .writeJson(settingsKey, next.toJson());
    state = AsyncData(next);
  }

  /// Turns "Keep it aside" on or off for [goalId].
  Future<void> setKept(int goalId, {required bool kept}) =>
      _save((s) => s.withKept(goalId, kept: kept));

  /// The person typed a new saved amount: whatever was left out after a
  /// dip no longer applies.
  Future<void> savedChanged(int goalId) =>
      _save((s) => s.withGoal(goalId, (k) => const KeptAside()));

  /// "Top it up from the next money in": the goal keeps all it holds aside,
  /// so the next money in fills it first. Home stops asking about this dip.
  Future<void> topUp(int goalId, int dipMinor) => _save(
    (s) => s.withGoal(goalId, (k) => k.copyWith(seenDipMinor: dipMinor)),
  );

  /// "Leave it as it is": the goal still shows what is saved, but [dipMinor]
  /// of it is no longer kept aside.
  Future<void> leave(int goalId, int dipMinor) => _save(
    (s) =>
        s.withGoal(goalId, (k) => KeptAside(gapMinor: k.gapMinor + dipMinor)),
  );

  /// The dip [goalId] had is over: a new one is asked about again.
  Future<void> dipOver(int goalId) =>
      _save((s) => s.withGoal(goalId, (k) => k.copyWith(seenDipMinor: 0)));
}

final keptAsideProvider =
    AsyncNotifierProvider<KeptAsideController, KeptAsideSettings>(
      KeptAsideController.new,
    );

/// The goals kept aside, with what each holds out of On hand and Safe to
/// spend. Reloaded with the Goals tab (see `refreshGoals`).
final goalsAsideProvider = FutureProvider<GoalsAside>((ref) async {
  final settings = await ref.watch(keptAsideProvider.future);
  if (settings.byGoal.isEmpty) return GoalsAside.none;
  final goals = await ref.watch(goalsRepositoryProvider).goals();
  return GoalsAside.of(
    goals,
    settings,
    currency: ref.watch(baseCurrencyProvider),
  );
});
