import '../time/calendar.dart';

/// "Which best describes you now?": one answer.
enum WhoYouAre {
  student('Student', 'Allowance, HELB, part-time work'),
  working('Working or in business', 'A job, a business or both'),
  family('Family', 'A household, school fees');

  const WhoYouAre(this.label, this.hint);

  final String label;
  final String hint;
}

/// "What matters most?": one or more.
enum WhatMatters {
  saveSteadily('Save more steadily', null, 'You said saving steadily matters.'),
  betterHabits(
    'Better money habits',
    null,
    'You said better money habits matter.',
  ),
  bigPurchase(
    'A big purchase',
    'Land, a car, a home',
    'You said a big purchase matters. A cushion comes first.',
  ),
  growBusiness(
    'Grow my business',
    null,
    'You said growing your business matters. A cushion keeps it going.',
  ),
  payOffDebt('Pay off debt', null, null),
  stopRunningOut(
    'Stop running out before payday',
    null,
    'You said running out before payday matters.',
  );

  const WhatMatters(this.label, this.hint, this.goalReason);

  final String label;
  final String? hint;

  /// Why an emergency fund is suggested, in the person's words; null for an
  /// answer that suggests none (debts have their own list).
  final String? goalReason;
}

/// "Which do you pay regularly?": each becomes a category in Plan.
enum RegularPayment {
  rent('Rent', 'rent'),
  groceries('Groceries', 'groceries'),
  transport('Transport', 'transport'),
  utilities('Utilities', 'utilities'),
  schoolFees('School fees', 'school_fees'),
  dataAirtime('Data and airtime', 'airtime_data'),
  chamaSacco('Chama or SACCO', 'savings'),
  loans('Loan repayments', 'loan_repayment'),
  giving('Church or giving', 'giving'),
  subscriptions('Subscriptions', null),
  familySupport('Family support', 'family_support'),
  somethingElse('Something else', null);

  const RegularPayment(this.label, this.categoryKey);

  final String label;

  /// The seeded category it is planned under; null when none fits, and it
  /// is then only remembered.
  final String? categoryKey;
}

/// The answers to About you, kept on this phone only, and whether its
/// offers have been seen.
class AboutYou {
  const AboutYou({
    this.who,
    this.matters = const {},
    this.pays = const {},
    this.answered = false,
    this.offeredOn,
    this.homeOfferClosed = false,
    this.goalOfferClosed = false,
  });

  /// Reads what [toJson] wrote; unknown names are skipped.
  factory AboutYou.fromJson(Map<String, Object?>? json) {
    T? named<T extends Enum>(List<T> values, Object? name) =>
        values.where((v) => v.name == name).firstOrNull;
    Set<T> all<T extends Enum>(List<T> values, Object? names) => {
      for (final name in names is List ? names : const []) ?named(values, name),
    };
    final offered = json?['offeredOn'];
    return AboutYou(
      who: named(WhoYouAre.values, json?['who']),
      matters: all(WhatMatters.values, json?['matters']),
      pays: all(RegularPayment.values, json?['pays']),
      answered: json?['answered'] == true,
      offeredOn: offered is String ? _date(offered) : null,
      homeOfferClosed: json?['homeOfferClosed'] == true,
      goalOfferClosed: json?['goalOfferClosed'] == true,
    );
  }

  final WhoYouAre? who;
  final Set<WhatMatters> matters;
  final Set<RegularPayment> pays;

  /// Whether the questions were gone through to the end, skipped or not.
  final bool answered;

  /// The day setup offered the questions; Home offers them once more from
  /// the day after, unless they were answered.
  final CalendarDate? offeredOn;

  /// Home's offer was taken or closed: from then on, only Profile.
  final bool homeOfferClosed;

  /// Goals' suggestion was added or put off, for good.
  final bool goalOfferClosed;

  /// Whether Home offers the questions on [today].
  bool homeOfferOn(CalendarDate today) {
    final offered = offeredOn;
    return !answered &&
        !homeOfferClosed &&
        offered != null &&
        today.compareTo(offered) > 0;
  }

  AboutYou copyWith({
    WhoYouAre? Function()? who,
    Set<WhatMatters>? matters,
    Set<RegularPayment>? pays,
    bool? answered,
    CalendarDate? offeredOn,
    bool? homeOfferClosed,
    bool? goalOfferClosed,
  }) => AboutYou(
    who: who == null ? this.who : who(),
    matters: matters ?? this.matters,
    pays: pays ?? this.pays,
    answered: answered ?? this.answered,
    offeredOn: offeredOn ?? this.offeredOn,
    homeOfferClosed: homeOfferClosed ?? this.homeOfferClosed,
    goalOfferClosed: goalOfferClosed ?? this.goalOfferClosed,
  );

  Map<String, Object?> toJson() => {
    'who': ?who?.name,
    'matters': [
      for (final m in WhatMatters.values)
        if (matters.contains(m)) m.name,
    ],
    'pays': [
      for (final p in RegularPayment.values)
        if (pays.contains(p)) p.name,
    ],
    'answered': answered,
    'offeredOn': ?offeredOn?.toString(),
    'homeOfferClosed': homeOfferClosed,
    'goalOfferClosed': goalOfferClosed,
  };
}

/// [minor] rounded up to a plain planning figure: to the next 1,000 from
/// 1,000 up, to the next 100 below that. [unit] is one whole unit of the
/// currency in minor units (100 for KES).
int roundUpForPlan(int minor, {int unit = 100}) {
  if (minor <= 0) return 0;
  final step = minor >= 1000 * unit ? 1000 * unit : 100 * unit;
  return ((minor + step - 1) ~/ step) * step;
}

/// A category Plan starts with, from an answer.
class PlanStart {
  const PlanStart(this.payment, this.categoryKey, this.amountMinor);

  final RegularPayment payment;
  final String categoryKey;

  /// A month's planned amount, from what the messages show.
  final int amountMinor;
}

/// What Plan starts with for [pays]: each answer with a category, at what
/// [spentByKey] shows a month of it costs (spending over [months] months,
/// by category key), rounded up. An answer whose spending the messages do
/// not show, or that has no category, is left for the person to add.
List<PlanStart> planStartFor(
  Set<RegularPayment> pays,
  Map<String, int> spentByKey, {
  int months = 3,
  int unit = 100,
}) => [
  for (final p in RegularPayment.values)
    if (pays.contains(p))
      if (p.categoryKey case final key?)
        if ((spentByKey[key] ?? 0) > 0)
          PlanStart(
            p,
            key,
            roundUpForPlan((spentByKey[key]! / months).ceil(), unit: unit),
          ),
];

/// The one goal Goals suggests from the answers.
class GoalSuggestion {
  const GoalSuggestion({
    required this.name,
    required this.reason,
    required this.halfMonth,
    required this.targetMinor,
    required this.monthlyMinor,
  });

  final String name;

  /// Why, in the person's words: "You said saving steadily matters."
  final String reason;

  /// Whether the goal is half a month of spending, rather than a month.
  final bool halfMonth;

  /// The goal: a month of spending, or half of one, rounded.
  final int targetMinor;

  /// What a month puts by to get there in a year.
  final int monthlyMinor;
}

/// An emergency fund saved over a year, when an answer in [answers] makes
/// it the first goal; null when none does, or the messages show no
/// spending to size it by. [monthSpendingMinor] is an average month's
/// spending. It is a month of spending, or half of one for a student.
GoalSuggestion? goalSuggestionFor(
  AboutYou answers,
  int monthSpendingMinor, {
  int unit = 100,
}) {
  if (monthSpendingMinor <= 0) return null;
  final reason =
      [
        for (final m in WhatMatters.values)
          if (answers.matters.contains(m)) ?m.goalReason,
      ].firstOrNull ??
      (answers.who == WhoYouAre.family
          ? 'You said you look after a family.'
          : null);
  if (reason == null) return null;
  final half = answers.who == WhoYouAre.student;
  final month = _roundToNearest(monthSpendingMinor, 1000 * unit);
  final target = half
      ? _roundToNearest(monthSpendingMinor ~/ 2, 1000 * unit)
      : month;
  if (target <= 0) return null;
  final step = 50 * unit;
  final monthly = ((target / 12) / step).ceil() * step;
  return GoalSuggestion(
    name: 'Emergency fund',
    reason: reason,
    halfMonth: half,
    targetMinor: target,
    monthlyMinor: monthly,
  );
}

int _roundToNearest(int minor, int step) =>
    ((minor + step ~/ 2) ~/ step) * step;

/// `2026-11-22` as a date, or null.
CalendarDate? _date(String text) {
  final parts = text.split('-').map(int.tryParse).toList();
  if (parts.length != 3 || parts.contains(null)) return null;
  return CalendarDate(parts[0]!, parts[1]!, parts[2]!);
}
