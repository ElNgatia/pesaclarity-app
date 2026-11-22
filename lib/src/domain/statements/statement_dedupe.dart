import '../enums.dart';

/// The fields used to tell whether two records are the same transaction.
class DedupeFields {
  const DedupeFields({
    required this.amountMinor,
    required this.direction,
    required this.occurredAt,
    this.receipt,
    this.counterparty,
    this.dedupeKey,
    this.dayOnly = false,
  });

  final int amountMinor;
  final TransactionDirection direction;
  final DateTime occurredAt;

  /// The institution's reference, such as an M-Pesa receipt number.
  final String? receipt;

  /// The other party's name as printed.
  final String? counterparty;

  /// ujumbe's receipt, amount and minute key.
  final String? dedupeKey;

  /// Whether [occurredAt] is only a date, as on a statement that prints no
  /// times (KCB's): the transaction happened some time that day.
  final bool dayOnly;
}

/// A transaction already in the ledger.
class LedgerCandidate {
  const LedgerCandidate(this.id, this.fields);

  final int id;
  final DedupeFields fields;
}

/// How close in time two records without a shared receipt must be to count
/// as the same transaction. SMS times are to the minute and can come from
/// when the phone received the message.
const defaultDedupeWindow = Duration(minutes: 10);

/// For each of [lines] from a statement, the id of the [existing] ledger
/// transaction it duplicates, or null when it is new.
///
/// A line matches, in order of preference: the same dedupe key; the same
/// receipt, amount and direction; when the receipts do not contradict
/// each other, the same amount, direction and counterparty within [window];
/// or, for a line with only a date ([DedupeFields.dayOnly]), the same
/// amount and direction on that day, at [dayOffset] from UTC, with no
/// receipt of the same shape that differs. A bank's SMS often names
/// neither the statement's reference nor its counterparty ("Pesalink
/// Outgoing"), or prints a reference of another kind. Each existing
/// transaction matches at most one line.
List<int?> matchStatementLines(
  List<DedupeFields> lines,
  List<LedgerCandidate> existing, {
  Duration window = defaultDedupeWindow,
  Duration dayOffset = Duration.zero,
}) {
  final used = <int>{};
  final result = List<int?>.filled(lines.length, null);

  void pass(bool Function(DedupeFields line, DedupeFields known) matches) {
    for (var i = 0; i < lines.length; i++) {
      if (result[i] != null) continue;
      LedgerCandidate? best;
      for (final candidate in existing) {
        if (used.contains(candidate.id)) continue;
        if (!matches(lines[i], candidate.fields)) continue;
        if (best == null ||
            _distance(lines[i], candidate.fields) <
                _distance(lines[i], best.fields)) {
          best = candidate;
        }
      }
      if (best != null) {
        used.add(best.id);
        result[i] = best.id;
      }
    }
  }

  pass((a, b) => a.dedupeKey != null && a.dedupeKey == b.dedupeKey);
  pass(
    (a, b) =>
        _sameReceipt(a, b) &&
        a.amountMinor == b.amountMinor &&
        a.direction == b.direction,
  );
  pass(
    (a, b) =>
        !_receiptsDiffer(a, b) &&
        a.amountMinor == b.amountMinor &&
        a.direction == b.direction &&
        _distance(a, b) <= window &&
        _sameParty(a.counterparty, b.counterparty),
  );
  pass(
    (a, b) =>
        a.dayOnly &&
        !_sameShapeReceiptsDiffer(a, b) &&
        a.amountMinor == b.amountMinor &&
        a.direction == b.direction &&
        _dayOf(a.occurredAt, dayOffset) == _dayOf(b.occurredAt, dayOffset),
  );
  return result;
}

DateTime _dayOf(DateTime time, Duration offset) {
  final t = time.toUtc().add(offset);
  return DateTime.utc(t.year, t.month, t.day);
}

/// Two receipts of one kind (the same length, such as two FT references)
/// that differ: two transactions. Receipts of different kinds, such as a
/// statement's FT reference and an SMS's long transfer code, can be the
/// same money.
bool _sameShapeReceiptsDiffer(DedupeFields a, DedupeFields b) {
  final ra = _normalReceipt(a.receipt), rb = _normalReceipt(b.receipt);
  return ra != null && rb != null && ra.length == rb.length && ra != rb;
}

Duration _distance(DedupeFields a, DedupeFields b) =>
    a.occurredAt.difference(b.occurredAt).abs();

String? _normalReceipt(String? receipt) {
  final r = receipt?.trim().toUpperCase();
  return r == null || r.isEmpty ? null : r;
}

bool _sameReceipt(DedupeFields a, DedupeFields b) {
  final r = _normalReceipt(a.receipt);
  return r != null && r == _normalReceipt(b.receipt);
}

bool _receiptsDiffer(DedupeFields a, DedupeFields b) {
  final ra = _normalReceipt(a.receipt), rb = _normalReceipt(b.receipt);
  return ra != null && rb != null && ra != rb;
}

bool _sameParty(String? a, String? b) {
  String? normal(String? s) {
    final n = s?.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    return n == null || n.isEmpty ? null : n;
  }

  final na = normal(a), nb = normal(b);
  return na != null && na == nb;
}
