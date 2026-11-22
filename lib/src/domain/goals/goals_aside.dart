import '../../core/money/money.dart';
import 'savings_goal.dart';

/// One goal the person keeps aside, as saved in the app's settings.
class KeptAside {
  const KeptAside({this.gapMinor = 0, this.seenDipMinor = 0})
    : assert(gapMinor >= 0, 'a gap is never negative'),
      assert(seenDipMinor >= 0, 'a dip is never negative');

  /// What the person chose to leave out after a dip ("Leave it as it is"):
  /// the goal still shows its saved amount, but this much is no longer
  /// kept aside.
  final int gapMinor;

  /// The dip the person has answered. Home's card stays away while the
  /// dip is no bigger than this.
  final int seenDipMinor;

  KeptAside copyWith({int? gapMinor, int? seenDipMinor}) => KeptAside(
    gapMinor: gapMinor ?? this.gapMinor,
    seenDipMinor: seenDipMinor ?? this.seenDipMinor,
  );
}

/// Which goals are kept aside ("Keep it aside" on the goal), by goal id.
/// Not a bank lock: the money stays where it is and can still be spent.
class KeptAsideSettings {
  const KeptAsideSettings([this.byGoal = const {}]);

  /// Reads what [toJson] wrote; anything it does not understand is left
  /// out.
  factory KeptAsideSettings.fromJson(Map<String, Object?>? json) {
    final goals = json?['goals'];
    if (goals is! Map) return const KeptAsideSettings();
    int amount(Object? value) => value is int && value > 0 ? value : 0;
    return KeptAsideSettings({
      for (final MapEntry(:key, :value) in goals.entries)
        if (int.tryParse('$key') case final id? when value is Map)
          id: KeptAside(
            gapMinor: amount(value['gap']),
            seenDipMinor: amount(value['seenDip']),
          ),
    });
  }

  final Map<int, KeptAside> byGoal;

  bool isKept(int goalId) => byGoal.containsKey(goalId);

  /// Turns [goalId]'s switch on or off. Turning it on starts afresh.
  KeptAsideSettings withKept(int goalId, {required bool kept}) {
    if (kept == isKept(goalId)) return this;
    final next = {...byGoal};
    kept ? next[goalId] = const KeptAside() : next.remove(goalId);
    return KeptAsideSettings(next);
  }

  /// [goalId]'s entry changed by [update]; unchanged when it is not kept.
  KeptAsideSettings withGoal(int goalId, KeptAside Function(KeptAside) update) {
    final current = byGoal[goalId];
    if (current == null) return this;
    return KeptAsideSettings({...byGoal, goalId: update(current)});
  }

  Map<String, Object?> toJson() => {
    'goals': {
      for (final MapEntry(:key, :value) in byGoal.entries)
        '$key': {'gap': value.gapMinor, 'seenDip': value.seenDipMinor},
    },
  };
}

/// One goal's money kept aside.
class GoalAside {
  const GoalAside({required this.goal, required this.asideMinor});

  final SavingsGoal goal;

  /// What it keeps out of On hand while nothing has dipped into it.
  final int asideMinor;
}

/// Spending that went past the free money and into a goal kept aside.
class GoalDip {
  const GoalDip({
    required this.goal,
    required this.dipMinor,
    required this.asideMinor,
    this.seen = false,
  });

  final SavingsGoal goal;

  /// How much of the goal's money was spent.
  final int dipMinor;

  /// What the goal keeps aside while nothing has dipped into it.
  final int asideMinor;

  /// Whether the person already answered a dip this big.
  final bool seen;

  /// What is still aside for the goal now.
  int get stillAsideMinor => asideMinor - dipMinor;
}

/// The goals kept aside in the base currency. Their saved money leaves On
/// hand and Safe to spend, as the rainy day fund does, while it stays in
/// M-Pesa or the bank. A goal kept in a savings app (a pocket, such as a
/// Chumz goal) is already out of On hand, so it is never counted here.
class GoalsAside {
  const GoalsAside(this.goals, {this.settings = const KeptAsideSettings()});

  factory GoalsAside.of(
    Iterable<SavingsGoal> goals,
    KeptAsideSettings settings, {
    String? currency,
  }) {
    currency ??= BaseCurrency.code;
    return GoalsAside([
      for (final goal in goals)
        if (canKeepAside(goal, baseCurrency: currency) &&
            settings.byGoal[goal.id] != null)
          GoalAside(
            goal: goal,
            asideMinor: _atLeastZero(
              goal.savedMinor - settings.byGoal[goal.id]!.gapMinor,
            ),
          ),
    ], settings: settings);
  }

  static const none = GoalsAside([]);

  final List<GoalAside> goals;
  final KeptAsideSettings settings;

  bool get isEmpty => totalMinor <= 0;

  /// Everything kept aside while nothing has dipped into it.
  int get totalMinor => goals.fold(0, (sum, g) => sum + g.asideMinor);

  /// What is still aside when the accounts, less the rainy day fund, hold
  /// [beforeGoalsMinor]: all of it, or as much as there is.
  int stillAsideMinor(int beforeGoalsMinor) {
    if (beforeGoalsMinor <= 0) return 0;
    return beforeGoalsMinor < totalMinor ? beforeGoalsMinor : totalMinor;
  }

  /// The goals spending has dipped into once the free money ran out, with
  /// [beforeGoalsMinor] as in [stillAsideMinor]. The last goal in the list
  /// is dipped into first, so the goals that come first keep theirs
  /// longest. Below zero, the accounts hold nothing at all and every goal
  /// is dipped into in full.
  List<GoalDip> dips(int beforeGoalsMinor) {
    var dipped = totalMinor - stillAsideMinor(beforeGoalsMinor);
    final result = <GoalDip>[];
    for (final aside in goals.reversed) {
      if (dipped <= 0) break;
      if (aside.asideMinor <= 0) continue;
      final dip = dipped < aside.asideMinor ? dipped : aside.asideMinor;
      dipped -= dip;
      final seen = settings.byGoal[aside.goal.id]?.seenDipMinor ?? 0;
      result.add(
        GoalDip(
          goal: aside.goal,
          dipMinor: dip,
          asideMinor: aside.asideMinor,
          seen: dip <= seen,
        ),
      );
    }
    return result.reversed.toList();
  }
}

/// Whether [goal] can be kept aside: one whose saved amount the person
/// types, in the base currency. Money in a savings app's pocket is already
/// out of On hand.
bool canKeepAside(SavingsGoal goal, {String? baseCurrency}) =>
    goal.backing == null &&
    goal.currency == (baseCurrency ?? BaseCurrency.code);

int _atLeastZero(int minor) => minor < 0 ? 0 : minor;
