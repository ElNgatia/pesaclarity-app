/// Messages pasted on iPhone: one or many M-Pesa or bank messages copied
/// from Messages and pasted into the app's box, as text.
library;

/// An M-Pesa message starts with its transaction code and "Confirmed":
/// `SKM2CD34EF Confirmed. …`.
final _mpesaStart = RegExp(r'^[A-Z0-9]{10}\s+Confirmed\b', multiLine: true);

/// A line with nothing on it but spaces: where one pasted message ends.
final _blankLine = RegExp(r'\n[ \t\r]*\n');

/// The separate messages in [text], in the order they were pasted.
///
/// Messages are split at blank lines, which the Paste button puts between
/// pastes, and before each M-Pesa transaction code that starts a line, so
/// messages pasted one under the other with no gap still come apart. A
/// message's own text is kept as it was copied, bar spaces at its ends, so
/// it reads, and dedupes, as the same message passed on by Shortcuts.
List<String> splitPastedMessages(String text) {
  final normalised = text.replaceAll('\r\n', '\n');
  final messages = <String>[];
  for (final block in normalised.split(_blankLine)) {
    final starts = [
      for (final m in _mpesaStart.allMatches(block))
        if (m.start > 0) m.start,
    ];
    var from = 0;
    for (final start in [...starts, block.length]) {
      final message = block.substring(from, start).trim();
      if (message.isNotEmpty) messages.add(message);
      from = start;
    }
  }
  return messages;
}

/// [existing] with [pasted] added at the end, a blank line between them so
/// they stay separate messages.
String appendPaste(String existing, String pasted) {
  final before = existing.trimRight();
  final after = pasted.trim();
  if (after.isEmpty) return existing;
  if (before.isEmpty) return after;
  return '$before\n\n$after';
}

/// `Nothing pasted yet`, `1 message pasted` or `13 messages pasted`.
String pastedCountLabel(int count) => switch (count) {
  0 => 'Nothing pasted yet',
  1 => '1 message pasted',
  _ => '$count messages pasted',
};
