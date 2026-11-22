/// What the person wants reminding about, and when.
class ReminderSettings {
  const ReminderSettings({
    this.enabled = false,
    this.bills = true,
    this.cardCharges = true,
    this.payday = true,
    this.dailySafeToSpend = false,
    this.dailyMinuteOfDay = 8 * 60,
    this.leadDays = 1,
    this.budgetAlerts = true,
    this.budgetAlertPercent = defaultBudgetAlertPercent,
    this.budgetAlertAgainWhenOver = true,
    this.budgetAlertAmountsOnLockScreen = false,
    this.budgetAlertCategoryPercents = const {},
  });

  /// Reads settings saved by [toJson]; unknown or missing values fall back to
  /// the defaults.
  factory ReminderSettings.fromJson(Map<String, Object?> json) {
    const defaults = ReminderSettings();
    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key]! as bool : fallback;
    int number(String key, int fallback, {required int max}) {
      final value = json[key];
      return value is int && value >= 0 && value <= max ? value : fallback;
    }

    return ReminderSettings(
      enabled: flag('enabled', defaults.enabled),
      bills: flag('bills', defaults.bills),
      cardCharges: flag('cardCharges', defaults.cardCharges),
      payday: flag('payday', defaults.payday),
      dailySafeToSpend: flag('dailySafeToSpend', defaults.dailySafeToSpend),
      dailyMinuteOfDay: number(
        'dailyMinuteOfDay',
        defaults.dailyMinuteOfDay,
        max: 24 * 60 - 1,
      ),
      leadDays: number('leadDays', defaults.leadDays, max: 31),
      budgetAlerts: flag('budgetAlerts', defaults.budgetAlerts),
      budgetAlertPercent: _percentOr(
        json['budgetAlertPercent'],
        defaults.budgetAlertPercent,
      ),
      budgetAlertAgainWhenOver: flag(
        'budgetAlertAgainWhenOver',
        defaults.budgetAlertAgainWhenOver,
      ),
      budgetAlertAmountsOnLockScreen: flag(
        'budgetAlertAmountsOnLockScreen',
        defaults.budgetAlertAmountsOnLockScreen,
      ),
      budgetAlertCategoryPercents:
          switch (json['budgetAlertCategoryPercents']) {
            final Map<String, Object?> shares => {
              for (final MapEntry(:key, :value) in shares.entries)
                if (int.tryParse(key) case final id?)
                  if (value == 0 || _percentOr(value, -1) > 0)
                    id: value! as int,
            },
            _ => const {},
          },
    );
  }

  /// The share of a category's plan that brings its first budget alert,
  /// before the person chooses another.
  static const defaultBudgetAlertPercent = 80;

  /// The shares offered for budget alerts; any whole percent from
  /// [minBudgetAlertPercent] to [maxBudgetAlertPercent] can be typed too.
  static const budgetAlertPercentChoices = [50, 70, 80, 90];
  static const minBudgetAlertPercent = 10;
  static const maxBudgetAlertPercent = 150;

  /// A category's own share that means no alerts for it.
  static const budgetAlertOff = 0;

  static int _percentOr(Object? value, int fallback) =>
      value is int &&
          value >= minBudgetAlertPercent &&
          value <= maxBudgetAlertPercent
      ? value
      : fallback;

  /// The lead times offered, in days before the due date.
  static const leadDayChoices = [0, 1, 2, 3, 7];

  /// Hour of day, Nairobi time, for bill, card charge and payday reminders.
  static const dueReminderMinuteOfDay = 9 * 60;

  /// Master switch. Nothing is scheduled while it is off.
  final bool enabled;
  final bool bills;
  final bool cardCharges;
  final bool payday;

  /// A notification each day with what is safe to spend.
  final bool dailySafeToSpend;

  /// When the daily safe-to-spend notification shows, in minutes after
  /// midnight Nairobi time.
  final int dailyMinuteOfDay;

  /// How many days before a bill or card charge to remind.
  final int leadDays;

  /// A notification and a card when a Plan category nears its plan.
  /// Notifications also need [enabled]; the card does not.
  final bool budgetAlerts;

  /// The share of a category's plan, in percent, that brings the first
  /// alert, unless the category has its own in
  /// [budgetAlertCategoryPercents].
  final int budgetAlertPercent;

  /// One more alert when a category goes over its plan.
  final bool budgetAlertAgainWhenOver;

  /// Whether budget alert notifications say amounts. Off, they name the
  /// category and the share only, so the lock screen shows no amount.
  final bool budgetAlertAmountsOnLockScreen;

  /// Categories with a share of their own, in percent, by category id;
  /// [budgetAlertOff] turns a category's alerts off.
  final Map<int, int> budgetAlertCategoryPercents;

  /// Whether budget alerts watch [categoryId].
  bool watchesCategory(int categoryId) =>
      budgetAlertCategoryPercents[categoryId] != budgetAlertOff;

  /// The share that brings [categoryId]'s first alert.
  int budgetAlertPercentFor(int categoryId) =>
      budgetAlertCategoryPercents[categoryId] ?? budgetAlertPercent;

  ReminderSettings copyWith({
    bool? enabled,
    bool? bills,
    bool? cardCharges,
    bool? payday,
    bool? dailySafeToSpend,
    int? dailyMinuteOfDay,
    int? leadDays,
    bool? budgetAlerts,
    int? budgetAlertPercent,
    bool? budgetAlertAgainWhenOver,
    bool? budgetAlertAmountsOnLockScreen,
    Map<int, int>? budgetAlertCategoryPercents,
  }) => ReminderSettings(
    enabled: enabled ?? this.enabled,
    bills: bills ?? this.bills,
    cardCharges: cardCharges ?? this.cardCharges,
    payday: payday ?? this.payday,
    dailySafeToSpend: dailySafeToSpend ?? this.dailySafeToSpend,
    dailyMinuteOfDay: dailyMinuteOfDay ?? this.dailyMinuteOfDay,
    leadDays: leadDays ?? this.leadDays,
    budgetAlerts: budgetAlerts ?? this.budgetAlerts,
    budgetAlertPercent: budgetAlertPercent ?? this.budgetAlertPercent,
    budgetAlertAgainWhenOver:
        budgetAlertAgainWhenOver ?? this.budgetAlertAgainWhenOver,
    budgetAlertAmountsOnLockScreen:
        budgetAlertAmountsOnLockScreen ?? this.budgetAlertAmountsOnLockScreen,
    budgetAlertCategoryPercents:
        budgetAlertCategoryPercents ?? this.budgetAlertCategoryPercents,
  );

  /// [categoryId] with its own alert share, or back to the share for all
  /// when [percent] is null.
  ReminderSettings withCategoryPercent(int categoryId, int? percent) =>
      copyWith(
        budgetAlertCategoryPercents: {
          for (final e in budgetAlertCategoryPercents.entries)
            if (e.key != categoryId) e.key: e.value,
          categoryId: ?percent,
        },
      );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'bills': bills,
    'cardCharges': cardCharges,
    'payday': payday,
    'dailySafeToSpend': dailySafeToSpend,
    'dailyMinuteOfDay': dailyMinuteOfDay,
    'leadDays': leadDays,
    'budgetAlerts': budgetAlerts,
    'budgetAlertPercent': budgetAlertPercent,
    'budgetAlertAgainWhenOver': budgetAlertAgainWhenOver,
    'budgetAlertAmountsOnLockScreen': budgetAlertAmountsOnLockScreen,
    'budgetAlertCategoryPercents': {
      for (final e in budgetAlertCategoryPercents.entries) '${e.key}': e.value,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is ReminderSettings &&
      other.enabled == enabled &&
      other.bills == bills &&
      other.cardCharges == cardCharges &&
      other.payday == payday &&
      other.dailySafeToSpend == dailySafeToSpend &&
      other.dailyMinuteOfDay == dailyMinuteOfDay &&
      other.leadDays == leadDays &&
      other.budgetAlerts == budgetAlerts &&
      other.budgetAlertPercent == budgetAlertPercent &&
      other.budgetAlertAgainWhenOver == budgetAlertAgainWhenOver &&
      other.budgetAlertAmountsOnLockScreen == budgetAlertAmountsOnLockScreen &&
      _sameMap(other.budgetAlertCategoryPercents, budgetAlertCategoryPercents);

  @override
  int get hashCode => Object.hash(
    enabled,
    bills,
    cardCharges,
    payday,
    dailySafeToSpend,
    dailyMinuteOfDay,
    leadDays,
    budgetAlerts,
    budgetAlertPercent,
    budgetAlertAgainWhenOver,
    budgetAlertAmountsOnLockScreen,
    budgetAlertCategoryPercents.length,
  );
}

bool _sameMap(Map<int, int> a, Map<int, int> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

/// How a budget alert share reads in settings, such as `80% of the plan`.
String budgetAlertPercentLabel(int percent) => '$percent% of the plan';

/// How a lead time reads in settings, such as `1 day before`.
String leadDaysLabel(int days) => switch (days) {
  0 => 'On the day',
  1 => '1 day before',
  7 => '1 week before',
  _ => '$days days before',
};
