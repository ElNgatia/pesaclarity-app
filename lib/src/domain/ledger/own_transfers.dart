import '../../core/money/money.dart';
import '../accounts/account_reference.dart';
import '../enums.dart';
import 'ledger_entry.dart';
import 'own_accounts.dart';

/// An outflow from one of the user's accounts and the matching inflow into
/// another.
class TransferPair {
  const TransferPair(this.outflowId, this.inflowId);

  final int outflowId;
  final int inflowId;

  @override
  bool operator ==(Object other) =>
      other is TransferPair &&
      other.outflowId == outflowId &&
      other.inflowId == inflowId;

  @override
  int get hashCode => Object.hash(outflowId, inflowId);

  @override
  String toString() => 'TransferPair($outflowId -> $inflowId)';
}

const _outflowKinds = {
  TransactionKind.sent,
  TransactionKind.paybill,
  TransactionKind.bank,
};

const _inflowKinds = {TransactionKind.received, TransactionKind.bank};

/// Default gap allowed between the two halves of an own transfer. Bank
/// messages can arrive some minutes after the M-Pesa one.
const defaultTransferWindow = Duration(minutes: 30);

/// How long an own transfer the person named waits for its other side, and
/// how far apart a suggested match may be.
const waitingTransferWindow = Duration(days: 3);

/// The offset statements print their dates at (East Africa Time): a
/// statement row with a date and no time falls at midnight there.
const statementDateOffset = Duration(hours: 3);

/// Whether [entry] is a statement row that printed only its date, such as
/// a KCB statement's, so its time is midnight rather than when it happened.
bool isDateOnly(LedgerEntry entry) {
  if (entry.source != TransactionSource.statement) return false;
  final t = entry.occurredAt.toUtc().add(statementDateOffset);
  return t.hour == 0 && t.minute == 0 && t.second == 0 && t.millisecond == 0;
}

Duration _gapOf(LedgerEntry a, LedgerEntry b) =>
    a.occurredAt.difference(b.occurredAt).abs();

/// How far apart [a] and [b] are, taking a date-only side ([isDateOnly])
/// as the whole of its day: zero when the other side is on that day.
Duration dayAwareGap(LedgerEntry a, LedgerEntry b) {
  final (day, other) = isDateOnly(a)
      ? (a, b)
      : isDateOnly(b)
      ? (b, a)
      : (null, null);
  if (day == null || other == null) return _gapOf(a, b);
  final start = day.occurredAt;
  final end = start.add(const Duration(days: 1));
  final t = other.occurredAt;
  if (t.isBefore(start)) return start.difference(t);
  if (!t.isBefore(end)) return t.difference(end);
  return Duration.zero;
}

/// The largest fee a transfer is taken to have cost when its message gives
/// none: KES 100, or 2% of the amount when that is more.
int transferFeeAllowanceMinor(int outflowMinor, String currency) {
  final floor = 100 * _pow10(minorUnitDigits(currency));
  final share = outflowMinor * 2 ~/ 100;
  return share > floor ? share : floor;
}

int _pow10(int digits) {
  var result = 1;
  for (var i = 0; i < digits; i++) {
    result *= 10;
  }
  return result;
}

/// How an outflow's amount relates to an inflow's.
enum TransferFit {
  /// The same amount.
  exact,

  /// The outflow is larger by its own fee, or by a plausible transfer fee
  /// when its message gave none.
  withFee,

  /// The outflow is larger by more than a plausible fee but within twice
  /// that: only ever suggested.
  loose,
}

/// The currency [entry]'s money moved in, before the ledger showed it in
/// the base currency.
String _movedIn(LedgerEntry entry) => entry.originalCurrency ?? entry.currency;

/// How [outflow] and [inflow]'s amounts fit as one transfer, or null when
/// they cannot be one: they must have moved in one currency. Shown in the
/// base currency, a transfer between two currencies would look like one
/// amount less a fee and never clear.
TransferFit? transferFit(LedgerEntry outflow, LedgerEntry inflow) {
  if (_movedIn(outflow) != _movedIn(inflow)) return null;
  final difference = outflow.amountMinor - inflow.amountMinor;
  if (difference == 0) return TransferFit.exact;
  if (difference < 0) return null;
  final allowance = outflow.feeMinor > 0
      ? outflow.feeMinor
      : transferFeeAllowanceMinor(outflow.amountMinor, outflow.currency);
  if (difference <= allowance) return TransferFit.withFee;
  final loose = transferFeeAllowanceMinor(
    outflow.amountMinor,
    outflow.currency,
  );
  return difference <= loose * 2 ? TransferFit.loose : null;
}

/// What the own transfer [out] and [into] are the two sides of lost on the
/// way: how much more left [out] than arrived in [into]. Above zero it is
/// the transfer's fee, on top of any fee [out]'s message printed (that one
/// is [out]'s own [LedgerEntry.feeMinor], already a fee); below zero more
/// arrived than left.
///
/// Null unless [out] is money out and [into] money in, paired with each
/// other, in one currency. A transfer between two currencies is not one
/// amount less a fee, so it is left to a rule of its own.
int? transferShortfall(LedgerEntry out, LedgerEntry into) {
  if (!out.isOutflow || !into.isInflow) return null;
  if (out.transferPairId != into.id || into.transferPairId != out.id) {
    return null;
  }
  if (out.currency != into.currency || _movedIn(out) != _movedIn(into)) {
    return null;
  }
  return out.amountMinor - into.amountMinor;
}

/// Whether [entry] may be one half of an own transfer: an unpaired move of
/// a kind transfers come as, not put in a non-transfer category.
bool _canPair(LedgerEntry entry) {
  if (entry.transferPairId != null || entry.isCorrection) return false;
  if (entry.transferAccountId != null) return true;
  final type = entry.categoryType;
  if (type != null && type != CategoryType.transfer) return false;
  return entry.isOutflow
      ? _outflowKinds.contains(entry.kind)
      : _inflowKinds.contains(entry.kind);
}

/// Whether the person's own naming of either side rules the pair out.
bool _namedApart(LedgerEntry out, LedgerEntry into) =>
    (out.transferAccountId != null &&
        out.transferAccountId != into.accountId) ||
    (into.transferAccountId != null && into.transferAccountId != out.accountId);

/// Whether either side was named as an own transfer by the person.
bool _named(LedgerEntry out, LedgerEntry into) =>
    out.transferAccountId != null || into.transferAccountId != null;

/// The account number [entry] paid into, as its message printed it: a
/// paybill's account reference (`131***4567` at KCB's paybill) or a bank
/// account sent to. Null when it names none.
String? paidToReference(LedgerEntry entry) {
  final value = entry.counterpartyValue;
  if (value == null) return null;
  return switch (entry.counterpartyKind) {
    PayeeIdentifierKind.paybill => switch (value.indexOf('#')) {
      final i when i >= 0 && i + 1 < value.length => value.substring(i + 1),
      _ => null,
    },
    PayeeIdentifierKind.account => value,
    _ => null,
  };
}

/// The bank account number [entry]'s message says the money came from or
/// went to (not a paybill reference, which may be a phone number). Null
/// when it names none.
String? _otherAccountNumber(LedgerEntry entry) =>
    entry.counterpartyKind == PayeeIdentifierKind.account
    ? entry.counterpartyValue
    : null;

/// Whether the account numbers the messages print rule [out] and [into]
/// out as one transfer: money in that names the bank account it came from,
/// when that is not [out]'s account, or money out that names the bank
/// account it went to, when that is not [into]'s.
bool _numberedApart(
  LedgerEntry out,
  LedgerEntry into,
  Map<int, String?> references,
) {
  bool apart(String? printed, int accountId) {
    final named = AccountReference.tryParse(printed);
    final own = AccountReference.tryParse(references[accountId]);
    return named != null && own != null && !named.sameAs(own);
  }

  return apart(_otherAccountNumber(into), out.accountId) ||
      apart(_otherAccountNumber(out), into.accountId);
}

/// Whether [out] paid into the account [into] is on, by the number both
/// messages print: a masked `131***4567` and a full `1310004567` agree.
bool paidIntoAccount(
  LedgerEntry out,
  LedgerEntry into,
  Map<int, String?> references,
) {
  final paid = AccountReference.tryParse(paidToReference(out));
  final own = AccountReference.tryParse(references[into.accountId]);
  return paid != null && own != null && paid.sameAs(own);
}

/// How far apart two sides printing the same transaction code may be.
const sameCodeTransferWindow = Duration(days: 1);

/// Whether [a] and [b] are the same transaction code: both printed, at
/// least six letters and digits, equal ignoring case and spaces.
bool sameTransactionCode(String? a, String? b) {
  final x = _code(a);
  return x != null && x == _code(b);
}

String? _code(String? receipt) {
  final c = receipt?.replaceAll(RegExp(r'\s+'), '').toUpperCase();
  return c == null || c.length < 6 ? null : c;
}

/// The codes [id]'s message prints: its own receipt ([receipts]) and the
/// other side's code ([linked]), such as Airtel's "Sender TID".
Set<String> _codesOf(
  int id,
  Map<int, String?> receipts,
  Map<int, String?> linked,
) => {?_code(receipts[id]), ?_code(linked[id])};

/// Whether the codes the two messages print rule them out as one movement:
/// one side prints the other side's code ([linked]) and the other side's
/// own receipt is another code. Airtel's "Sender TID" is the receipt of the
/// M-Pesa send it came from; a send with any other receipt is other money.
bool _codedApart(
  LedgerEntry out,
  LedgerEntry into,
  Map<int, String?> receipts,
  Map<int, String?> linked,
) {
  bool apart(LedgerEntry a, LedgerEntry b) {
    final theirs = _code(linked[a.id]);
    final own = _code(receipts[b.id]);
    return theirs != null && own != null && theirs != own;
  }

  return apart(into, out) || apart(out, into);
}

/// How sure the app is that [out] and [into] are one move between the
/// person's own accounts (decision 0030).
enum MoveCertainty {
  /// Both print one transaction code (rule 2).
  code,

  /// [out] paid into [into]'s account by the number both print, or one
  /// side names the other's account: an own phone number, an own account
  /// number or an own paybill account (rule 3).
  named,

  /// The person named the other account, matched it, or answered Yes for
  /// this sender (rule 5).
  person,

  /// Only the amount and the time agree: a guess, held as a move until the
  /// person answers "Was this a move between your accounts?" (rule 5).
  guess,
}

/// How sure [out] and [into], two sides already paired, are one move, for
/// asking the person about guesses; see [findOwnTransfers] for the inputs.
MoveCertainty moveCertainty(
  LedgerEntry out,
  LedgerEntry into, {
  Map<int, String?> references = const {},
  Map<int, String?> receipts = const {},
  Map<int, String?> linked = const {},
  OwnAccounts own = const OwnAccounts.none(),
  Map<String, bool> answers = const {},
}) {
  final codes = _codesOf(out.id, receipts, linked);
  if (codes.intersection(_codesOf(into.id, receipts, linked)).isNotEmpty) {
    return MoveCertainty.code;
  }
  if (paidIntoAccount(out, into, references) ||
      own.namedBy(out) == into.accountId ||
      own.namedBy(into) == out.accountId) {
    return MoveCertainty.named;
  }
  if (_named(out, into) || answers[moveSenderKey(out, into)] == true) {
    return MoveCertainty.person;
  }
  return MoveCertainty.guess;
}

/// Whether what the messages print rules [out] and [into] out as one move
/// between own accounts, whatever their amounts and times: a side names
/// another account of the person's, an account or phone number that is not
/// the other account's, or a code the other side does not print, or the
/// person said No for this sender.
bool movesApart(
  LedgerEntry out,
  LedgerEntry into, {
  Map<int, String?> references = const {},
  Map<int, String?> receipts = const {},
  Map<int, String?> linked = const {},
  OwnAccounts own = const OwnAccounts.none(),
  Map<String, bool> answers = const {},
}) {
  if (_namedApart(out, into)) return true;
  if (_numberedApart(out, into, references)) return true;
  if (_codedApart(out, into, receipts, linked)) return true;
  final outNames = own.namedBy(out);
  final inNames = own.namedBy(into);
  if (outNames != null && outNames != into.accountId) return true;
  if (inNames != null && inNames != out.accountId) return true;
  if (outNames == null && own.namesAnotherPhone(out, into.accountId)) {
    return true;
  }
  if (inNames == null && own.namesAnotherPhone(into, out.accountId)) {
    return true;
  }
  return !_named(out, into) && answers[moveSenderKey(out, into)] == false;
}

/// Finds own-account transfers (bank to M-Pesa, M-Pesa to bank, M-Pesa to
/// Airtel Money, money market and savings moves) among entries not already
/// paired, by decision 0030's rules.
///
/// Two sides that print one transaction code are one movement whatever
/// else either names, equal amounts within [sameCodeTransferWindow] (rule
/// 2). The code is a side's own receipt ([receipts], by id) or the other
/// side's code its message prints ([linked], by id): Airtel's "Sender TID",
/// the M-Pesa ref in a bank's send to a mobile wallet, a fund's
/// "Transaction ref". Compared by [sameTransactionCode].
///
/// Otherwise two entries pair when they are on different accounts, in the
/// same currency, one out and one in, and the amounts are equal or the
/// outflow is larger by a transfer fee: its own fee when its message gave
/// one, else up to [transferFeeAllowanceMinor]. Only send, paybill and bank
/// movements qualify, and an entry the user has put in a non-transfer
/// category is left alone. Then, by how sure the pair is (rule 3):
///
/// * an outflow whose message names the account number it paid into
///   ([references], each account's number, by id), such as an M-Pesa
///   payment to a bank's paybill for a masked account, or an entry the
///   person named as an own transfer, waits up to [waitingTransferWindow];
/// * a side naming one of the person's own accounts in [own] (an own phone
///   number, account number or paybill account) pairs with the other
///   side on that account within [window];
/// * with neither, the pair is a guess within [window]: held as a move and
///   asked about (rule 5, see [moveCertainty]) unless the person already
///   answered for this sender in [answers] ([moveSenderKey]): Yes pairs it
///   as theirs, No leaves it apart.
///
/// Pairs [movesApart] rules out never pair, and pairs in [declined] were
/// unmatched by the person and never pair again.
///
/// When several candidates fit, pairs by one code come first, then pairs
/// confirmed by a number, then equal amounts before ones with a fee, then
/// the closest in time, so each entry is used at most once and the result
/// does not depend on input order.
List<TransferPair> findOwnTransfers(
  Iterable<LedgerEntry> entries, {
  Duration window = defaultTransferWindow,
  Set<TransferPair> declined = const {},
  Map<int, String?> references = const {},
  Map<int, String?> receipts = const {},
  Map<int, String?> linked = const {},
  OwnAccounts own = const OwnAccounts.none(),
  Map<String, bool> answers = const {},
}) {
  final outflows = <String, List<LedgerEntry>>{};
  final inflows = <String, List<LedgerEntry>>{};
  for (final entry in entries) {
    if (!_canPair(entry)) continue;
    // Money typed in by hand pairs only when the person said where it went.
    if (entry.source == TransactionSource.manual &&
        entry.transferAccountId == null) {
      continue;
    }
    (entry.isOutflow ? outflows : inflows)
        .putIfAbsent(_movedIn(entry), () => [])
        .add(entry);
  }

  final candidates = <(int, int, Duration, LedgerEntry, LedgerEntry)>[];
  // One transaction code on both sides: the same movement, such as a fund's
  // "Transaction ref: QAB1CD2EF3" and M-Pesa's QAB1CD2EF3, or Airtel's
  // "Sender TID" and the M-Pesa send it came from, whatever either names
  // or however it was read. It wins over everything else.
  final byCode = <String, List<LedgerEntry>>{};
  for (final entry in entries) {
    if (entry.transferPairId != null || entry.isCorrection) continue;
    final type = entry.categoryType;
    if (type != null && type != CategoryType.transfer) continue;
    for (final code in _codesOf(entry.id, receipts, linked)) {
      (byCode[code] ??= []).add(entry);
    }
  }
  final coded = <TransferPair>{};
  for (final sides in byCode.values) {
    for (final out in sides.where((e) => e.isOutflow)) {
      for (final into in sides.where((e) => e.isInflow)) {
        final pair = TransferPair(out.id, into.id);
        if (out.accountId == into.accountId ||
            out.currency != into.currency ||
            out.amountMinor != into.amountMinor ||
            declined.contains(pair) ||
            !coded.add(pair)) {
          continue;
        }
        final gap = out.occurredAt.difference(into.occurredAt).abs();
        if (gap <= sameCodeTransferWindow) {
          candidates.add((-1, 0, gap, out, into));
        }
      }
    }
  }
  for (final MapEntry(key: currency, value: outs) in outflows.entries) {
    final ins = inflows[currency];
    if (ins == null) continue;
    for (final out in outs) {
      for (final into in ins) {
        if (out.accountId == into.accountId) continue;
        if (declined.contains(TransferPair(out.id, into.id))) continue;
        if (movesApart(
          out,
          into,
          references: references,
          receipts: receipts,
          linked: linked,
          own: own,
          answers: answers,
        )) {
          continue;
        }
        final fit = transferFit(out, into);
        if (fit == null || fit == TransferFit.loose) continue;
        final byNumber = paidIntoAccount(out, into, references);
        final namesOwn =
            own.namedBy(out) == into.accountId ||
            own.namedBy(into) == out.accountId;
        // A statement row with only a date happened some time that day.
        final gap = namesOwn ? dayAwareGap(out, into) : _gapOf(out, into);
        final allowed = _named(out, into) || byNumber
            ? waitingTransferWindow
            : window;
        if (gap > allowed) continue;
        final sure = byNumber || namesOwn;
        candidates.add((sure ? 0 : 1, fit.index, gap, out, into));
      }
    }
  }
  candidates.sort((a, b) {
    final byNumber = a.$1.compareTo(b.$1);
    if (byNumber != 0) return byNumber;
    final byFit = a.$2.compareTo(b.$2);
    if (byFit != 0) return byFit;
    final byGap = a.$3.compareTo(b.$3);
    if (byGap != 0) return byGap;
    final byOut = a.$4.id.compareTo(b.$4.id);
    return byOut != 0 ? byOut : a.$5.id.compareTo(b.$5.id);
  });

  final used = <int>{};
  final pairs = <TransferPair>[];
  for (final (_, _, _, out, into) in candidates) {
    if (used.contains(out.id) || used.contains(into.id)) continue;
    used
      ..add(out.id)
      ..add(into.id);
    pairs.add(TransferPair(out.id, into.id));
  }
  return pairs;
}

/// An entry that may be the other side of an own transfer, and how well it
/// fits.
class TransferSuggestion {
  const TransferSuggestion({
    required this.partner,
    required this.fit,
    required this.gap,
  });

  final LedgerEntry partner;
  final TransferFit fit;
  final Duration gap;

  /// What the outflow cost over the inflow, for an entry of
  /// [entryAmountMinor]; zero for equal amounts.
  int feeMinor(int entryAmountMinor) =>
      (entryAmountMinor - partner.amountMinor).abs();
}

/// Entries that could be [entry]'s other side, best first: unpaired, on
/// another account, the opposite way, in the same currency, up to
/// [waitingTransferWindow] apart, with equal amounts or the outflow larger
/// by up to twice a plausible fee. The currency is the one the money moved
/// in, not the base currency the ledger may show it in. For the person to
/// choose; never paired without them.
List<TransferSuggestion> suggestTransferPartners(
  LedgerEntry entry,
  Iterable<LedgerEntry> entries, {
  Set<TransferPair> declined = const {},
  int limit = 3,
}) {
  if (entry.transferPairId != null || entry.isCorrection) return const [];
  final found = <TransferSuggestion>[];
  for (final other in entries) {
    if (other.id == entry.id ||
        other.accountId == entry.accountId ||
        other.direction == entry.direction ||
        _movedIn(other) != _movedIn(entry)) {
      continue;
    }
    final out = entry.isOutflow ? entry : other;
    final into = entry.isOutflow ? other : entry;
    if (declined.contains(TransferPair(out.id, into.id))) continue;
    if (_namedApart(out, into)) continue;
    if (!_canPair(other)) continue;
    final fit = transferFit(out, into);
    if (fit == null) continue;
    final gap = out.occurredAt.difference(into.occurredAt).abs();
    if (gap > waitingTransferWindow) continue;
    found.add(TransferSuggestion(partner: other, fit: fit, gap: gap));
  }
  found.sort((a, b) {
    final byFit = a.fit.index.compareTo(b.fit.index);
    return byFit != 0 ? byFit : a.gap.compareTo(b.gap);
  });
  return found.take(limit).toList();
}

/// Returns [entries] with both halves of each pair pointing at each other.
List<LedgerEntry> applyTransferPairs(
  Iterable<LedgerEntry> entries,
  Iterable<TransferPair> pairs,
) {
  final partner = <int, int>{};
  for (final pair in pairs) {
    partner[pair.outflowId] = pair.inflowId;
    partner[pair.inflowId] = pair.outflowId;
  }
  return [
    for (final entry in entries)
      partner.containsKey(entry.id)
          ? entry.copyWith(transferPairId: partner[entry.id])
          : entry,
  ];
}
