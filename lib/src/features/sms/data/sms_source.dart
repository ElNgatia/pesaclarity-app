import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ujumbe/ujumbe.dart';

/// Whether the app may read SMS.
enum SmsAccess {
  granted,

  /// Refused, but the app may ask again.
  denied,

  /// Refused for good; only the phone's settings can grant it now.
  blocked,

  /// This platform has no SMS inbox the app can read.
  unavailable,
}

/// A message with the SIM it arrived on, on a phone that says: an opaque
/// key of the SIM subscription, never the phone number. It tells two M-Pesa
/// lines on one phone apart (see `MpesaLines`).
class LineSmsMessage extends SmsMessage {
  const LineSmsMessage({
    required super.sender,
    required super.body,
    required super.receivedAt,
    required this.line,
  });

  /// `sim:` and the subscription id the phone gave.
  final String line;
}

/// The SIM [message] arrived on, when the phone said.
String? lineOf(SmsMessage message) =>
    message is LineSmsMessage ? message.line : null;

/// The phone's SMS inbox and incoming messages, limited to given senders.
abstract interface class SmsSource {
  Future<SmsAccess> access();

  /// Shows the system permission dialog, unless access is already granted.
  Future<SmsAccess> requestAccess();

  /// Opens the app's page in the phone's settings.
  Future<void> openSettings();

  /// Inbox messages from [senders] received at or after [since], oldest
  /// first. Messages from any other sender are never read.
  Future<List<SmsMessage>> readInbox({
    required Set<String> senders,
    required DateTime since,
  });

  /// Messages from [senders] as they arrive, while listened to.
  Stream<SmsMessage> incoming(Set<String> senders);

  /// Lets go of the messages from [senders] received from [since] up to
  /// [before]: what a scan has just read. Only sources that keep their own
  /// copy, such as [ShortcutSmsSource], drop anything. Messages from other
  /// senders stay, since another space may read them.
  Future<void> release({
    required Set<String> senders,
    required DateTime since,
    required DateTime before,
  });
}

/// [SmsSource] backed by the Android platform channel in `SmsChannel.kt`.
class PlatformSmsSource implements SmsSource {
  const PlatformSmsSource();

  static const _methods = MethodChannel('com.pesaclarity.app/sms');
  static const _events = EventChannel('com.pesaclarity.app/sms/incoming');

  @override
  Future<SmsAccess> access() => _accessCall('access');

  @override
  Future<SmsAccess> requestAccess() => _accessCall('requestAccess');

  Future<SmsAccess> _accessCall(String method) async {
    try {
      final name = await _methods.invokeMethod<String>(method);
      return SmsAccess.values.asNameMap()[name] ?? SmsAccess.denied;
    } on MissingPluginException {
      return SmsAccess.unavailable;
    }
  }

  @override
  Future<void> openSettings() => _methods.invokeMethod<void>('openSettings');

  @override
  Future<List<SmsMessage>> readInbox({
    required Set<String> senders,
    required DateTime since,
  }) async {
    if (senders.isEmpty) return const [];
    final rows = await _methods.invokeListMethod<Map<Object?, Object?>>(
      'readInbox',
      {
        'senders': senders.toList(),
        'sinceMillis': since.millisecondsSinceEpoch,
      },
    );
    return [
      for (final row in rows ?? const <Map<Object?, Object?>>[]) _fromMap(row),
    ];
  }

  @override
  Stream<SmsMessage> incoming(Set<String> senders) => senders.isEmpty
      ? const Stream.empty()
      : _events
            .receiveBroadcastStream(senders.toList())
            .map((event) => _fromMap(event as Map<Object?, Object?>));

  /// The phone's inbox keeps its messages; nothing to let go of.
  @override
  Future<void> release({
    required Set<String> senders,
    required DateTime since,
    required DateTime before,
  }) async {}

  static SmsMessage _fromMap(Map<Object?, Object?> map) {
    final sender = map['sender']! as String;
    final body = map['body']! as String;
    final receivedAt = DateTime.fromMillisecondsSinceEpoch(
      map['receivedAtMillis']! as int,
      isUtc: true,
    );
    // Phones that keep no SIM with a message leave it out, or report a
    // negative id.
    final subscription = map['subscriptionId'];
    return subscription is int && subscription >= 0
        ? LineSmsMessage(
            sender: sender,
            body: body,
            receivedAt: receivedAt,
            line: 'sim:$subscription',
          )
        : SmsMessage(sender: sender, body: body, receivedAt: receivedAt);
  }

  /// [map] as the platform channel sends it, for tests.
  @visibleForTesting
  static SmsMessage fromChannel(Map<Object?, Object?> map) => _fromMap(map);
}

/// The Shortcuts automation that passes messages on iPhone.
abstract interface class ShortcutConnection {
  /// When the automation last passed a message, or null before the first.
  Future<DateTime?> lastArrival();

  /// Opens the Shortcuts app, where the automation is set up.
  Future<void> openShortcuts();
}

/// [SmsSource] on iPhone, where apps cannot read messages. A Shortcuts
/// automation passes each M-Pesa or bank message to the app's "Add
/// transaction from message" action, which queues it in a file only this app
/// can open (`MessageQueue.swift`). The channel has the Android method names.
class ShortcutSmsSource extends PlatformSmsSource
    implements ShortcutConnection {
  const ShortcutSmsSource();

  static const _methods = MethodChannel('com.pesaclarity.app/sms');

  @override
  Future<void> release({
    required Set<String> senders,
    required DateTime since,
    required DateTime before,
  }) async {
    if (senders.isEmpty) return;
    await _methods.invokeMethod<void>('release', {
      'senders': senders.toList(),
      'sinceMillis': since.millisecondsSinceEpoch,
      'beforeMillis': before.millisecondsSinceEpoch,
    });
  }

  @override
  Future<DateTime?> lastArrival() async {
    final millis = await _methods.invokeMethod<int>('lastArrival');
    return millis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  @override
  Future<void> openShortcuts() => _methods.invokeMethod<void>('openShortcuts');
}

final smsSourceProvider = Provider<SmsSource>(
  (ref) => defaultTargetPlatform == TargetPlatform.iOS
      ? const ShortcutSmsSource()
      : const PlatformSmsSource(),
);
