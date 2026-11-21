/// How long "Not now" hides Home's "Messages may be missed" card.
const batteryNotNowFor = Duration(days: 7);

/// What the phone says about its battery saver and this app.
class BatteryStatus {
  const BatteryStatus({required this.restricted, required this.manufacturer});

  /// The battery saver may put the app to sleep: Android is not ignoring
  /// battery optimisations for it.
  ///
  /// Samsung's "Sleeping apps" and "Deep sleeping apps" lists cannot be
  /// read by apps, so an app on them can still read as not restricted. The
  /// sheet's Samsung steps cover those lists.
  final bool restricted;

  /// The phone's maker, as Android reports it, such as "samsung".
  final String manufacturer;

  /// Samsung (One UI) phones, which have their own sleeping lists.
  bool get isSamsung => manufacturer.trim().toLowerCase() == 'samsung';
}

/// What the app remembers about the card, kept with Personal.
class BatteryPromptState {
  const BatteryPromptState({this.notNowAt});

  factory BatteryPromptState.fromJson(Map<String, Object?>? json) {
    final at = json?['notNowAt'];
    return BatteryPromptState(
      notNowAt: at is String ? DateTime.tryParse(at) : null,
    );
  }

  /// When "Not now" was last tapped, or null.
  final DateTime? notNowAt;

  Map<String, Object?> toJson() => {
    if (notNowAt != null) 'notNowAt': notNowAt!.toUtc().toIso8601String(),
  };
}

/// Whether Home shows "Messages may be missed": only on Android, only once
/// messages are being read (accounts chosen and SMS allowed), only while the
/// battery saver may put the app to sleep, and not for [batteryNotNowFor]
/// after "Not now". After that it comes back only if still restricted.
bool showBatteryCard({
  required bool android,
  required bool smsReady,
  required BatteryStatus? status,
  required BatteryPromptState prompt,
  required DateTime now,
}) {
  if (!android || !smsReady || status == null || !status.restricted) {
    return false;
  }
  final notNowAt = prompt.notNowAt;
  return notNowAt == null || !now.isBefore(notNowAt.add(batteryNotNowFor));
}

/// One step on the "Keep Pesa Clarity awake" sheet.
class BatteryStep {
  const BatteryStep({required this.title, this.path = const [], this.detail});

  final String title;

  /// Where to tap in the phone's Settings, one place per entry, shown
  /// joined with ›.
  final List<String> path;

  /// A line under the path, or under the title when there is no path.
  final String? detail;
}

/// The sheet's text for this phone: Samsung's exact paths and its sleeping
/// lists, or Android's usual path elsewhere.
class BatterySteps {
  const BatterySteps({required this.intro, required this.steps});

  final String intro;
  final List<BatteryStep> steps;

  static const _comeBack = BatteryStep(
    title: 'Come back here',
    detail: 'The app checks again on its own.',
  );

  static const _runInBackground = 'Let it run in the background';

  static const _appBattery = [
    'Settings',
    'Apps',
    'Pesa Clarity',
    'Battery',
    'Unrestricted',
  ];

  static const samsung = BatterySteps(
    intro:
        'Samsung puts apps to sleep to save battery. Change these two '
        'settings so new messages are read as they arrive.',
    steps: [
      BatteryStep(title: _runInBackground, path: _appBattery),
      BatteryStep(
        title: 'Take it off the sleeping lists',
        path: ['Settings', 'Battery', 'Background usage limits'],
        detail:
            'Remove Pesa Clarity from Sleeping apps and from Deep sleeping '
            'apps.',
      ),
      _comeBack,
    ],
  );

  static const other = BatterySteps(
    intro:
        'Your phone puts apps to sleep to save battery. Change this setting '
        'so new messages are read as they arrive.',
    steps: [
      BatteryStep(
        title: _runInBackground,
        path: _appBattery,
        detail: 'On some phones this is called "Don\'t optimise".',
      ),
      _comeBack,
    ],
  );

  static BatterySteps forPhone(BatteryStatus? status) =>
      (status?.isSamsung ?? false) ? samsung : other;
}
