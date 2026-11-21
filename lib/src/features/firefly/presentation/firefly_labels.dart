import '../../../domain/firefly/firefly_server.dart';
import '../application/firefly_settings.dart';

/// Profile's Firefly III row under its name: what it is for while off, and
/// where data goes and when it last went while on. A problem never shows
/// here, only on the Firefly III screen.
String fireflyRowSummary(FireflySettings? settings, DateTime now) {
  final host = settings?.host;
  if (settings == null || !settings.on || host == null) {
    return 'Off · Send to your own server';
  }
  final last = settings.lastSentAt;
  return last == null
      ? 'Sending to $host'
      : 'Sending to $host · last sent ${sentAgoLabel(last, now)}';
}
