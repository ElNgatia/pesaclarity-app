import '../../../domain/firefly/firefly_server.dart';
import '../../../domain/time/calendar.dart';

/// Where the Firefly III settings live: Personal's settings, whichever space
/// is open. The token is never here (see [fireflyTokenKey]).
const fireflySettingsKey = 'firefly.settings';

/// The secure store key of the personal access token: on this phone only,
/// never in a database, a backup, a log or a crash report.
const fireflyTokenKey = 'firefly.token';

/// What stopped the last send, shown only on the Firefly III screen.
enum FireflyProblem {
  /// The server did not answer.
  unreachable,

  /// Firefly III refused the token.
  tokenRefused,

  /// The certificate changed, or is not one the phone trusts.
  certificate,

  /// The address redirects somewhere else.
  redirected,

  /// Something answered that is not Firefly III 6 or later.
  notFirefly,
}

/// How far back to send.
enum FireflySendFrom {
  /// 1 January this year, the usual.
  thisYear,

  /// The 1st of this month.
  thisMonth,

  /// Every transaction.
  everything,
}

/// The Firefly III connection's settings (decision 0029, section 1).
class FireflySettings {
  const FireflySettings({
    this.address,
    this.plainConfirmed = false,
    this.trusted,
    this.sendFrom = FireflySendFrom.thisYear,
    this.fromDay,
    this.on = false,
    this.lastSentAt,
    this.problem,
    this.version,
  });

  static FireflySettings fromJson(Map<String, Object?>? json) {
    if (json == null) return const FireflySettings();
    final from = json['fromDay'];
    final last = json['lastSentAt'];
    return FireflySettings(
      address: json['address'] is String ? json['address'] as String : null,
      plainConfirmed: json['plainConfirmed'] == true,
      trusted: TrustedCertificate.fromJson(json['trusted']),
      sendFrom:
          FireflySendFrom.values.asNameMap()[json['sendFrom']] ??
          FireflySendFrom.thisYear,
      fromDay: from is String ? _day(from) : null,
      on: json['on'] == true,
      lastSentAt: last is String ? DateTime.tryParse(last) : null,
      problem: FireflyProblem.values.asNameMap()[json['problem']],
      version: json['version'] is String ? json['version'] as String : null,
    );
  }

  /// The server address as typed and checked, such as
  /// `https://firefly.example.home`.
  final String? address;

  /// The person confirmed plain http for [address], on their home network.
  final bool plainConfirmed;

  /// A certificate the person chose to trust, for its host only.
  final TrustedCertificate? trusted;

  /// What the Send from choice was.
  final FireflySendFrom sendFrom;

  /// The day sending starts from, fixed when sending starts or Send from
  /// changes, so it does not move at the new year.
  final CalendarDate? fromDay;

  /// Sending is on.
  final bool on;
  final DateTime? lastSentAt;
  final FireflyProblem? problem;

  /// Firefly III's version at the last check.
  final String? version;

  FireflyServerAddress? get server =>
      address == null ? null : parseFireflyAddress(address!).address;

  /// The server's host, for "Sending to firefly.example.home".
  String? get host => server?.host;

  FireflySettings copyWith({
    String? address,
    bool? plainConfirmed,
    TrustedCertificate? trusted,
    bool clearTrusted = false,
    FireflySendFrom? sendFrom,
    CalendarDate? fromDay,
    bool? on,
    DateTime? lastSentAt,
    bool clearLastSent = false,
    FireflyProblem? problem,
    bool clearProblem = false,
    String? version,
  }) => FireflySettings(
    address: address ?? this.address,
    plainConfirmed: plainConfirmed ?? this.plainConfirmed,
    trusted: clearTrusted ? null : trusted ?? this.trusted,
    sendFrom: sendFrom ?? this.sendFrom,
    fromDay: fromDay ?? this.fromDay,
    on: on ?? this.on,
    lastSentAt: clearLastSent ? null : lastSentAt ?? this.lastSentAt,
    problem: clearProblem ? null : problem ?? this.problem,
    version: version ?? this.version,
  );

  Map<String, Object?> toJson() => {
    'address': ?address,
    'plainConfirmed': plainConfirmed,
    'trusted': ?trusted?.toJson(),
    'sendFrom': sendFrom.name,
    'fromDay': ?fromDay?.toString(),
    'on': on,
    'lastSentAt': ?lastSentAt?.toUtc().toIso8601String(),
    'problem': ?problem?.name,
    'version': ?version,
  };
}

CalendarDate? _day(String text) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
  if (match == null) return null;
  return CalendarDate(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

/// The day [from] starts sending, on [today].
CalendarDate fireflyFromDay(FireflySendFrom from, CalendarDate today) =>
    switch (from) {
      FireflySendFrom.thisYear => CalendarDate(today.year, 1, 1),
      FireflySendFrom.thisMonth => CalendarDate(today.year, today.month, 1),
      FireflySendFrom.everything => CalendarDate(1970, 1, 1),
    };

/// How a Send from choice reads: `1 Jan 2026`, `1 Nov 2026`, `Everything`.
String fireflyFromLabel(FireflySendFrom from, CalendarDate today) {
  if (from == FireflySendFrom.everything) return 'Everything';
  final day = fireflyFromDay(from, today);
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${day.day} ${months[day.month - 1]} ${day.year}';
}
