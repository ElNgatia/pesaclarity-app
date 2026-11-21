import '../enums.dart';

/// How far apart two messages about the same money may be when only one of
/// them prints a reference. A bank's plain alert ("your acc ... has been
/// debited") and its own confirmation of the same transfer arrive minutes
/// apart (one when the transfer starts, one when it completes); fifteen
/// minutes covers a slow transfer while two separate payments of exactly
/// the same amount on one account in that time stay rare.
const twinWindow = Duration(minutes: 15);

/// How far apart two messages printing the same reference may be: a bank's
/// confirmation of an M-Pesa payment and M-Pesa's own message.
const sameReceiptWindow = Duration(days: 1);

/// What [twinMatch] compares about one stored or incoming message.
class TwinFacts {
  const TwinFacts({
    required this.at,
    required this.amountMinor,
    required this.direction,
    required this.currency,
    required this.kind,
    this.receipt,
    this.messageHash,
    this.twinHash,
    this.counterpartyName,
    this.readBy,
  });

  final DateTime at;
  final int amountMinor;
  final TransactionDirection direction;
  final String currency;
  final TransactionKind kind;
  final String? receipt;
  final String? messageHash;

  /// The message already merged into this one, for a stored row.
  final String? twinHash;

  /// The other party's name as the message printed it.
  final String? counterpartyName;

  /// The readers that read the message, such as `0.3.0 kcb@0.2.0`
  /// (see [packOf]).
  final String? readBy;
}

/// The pack that read a message, from its transaction's `readBy` such as
/// `0.3.0 kcb@0.2.0`; null when the bundled readers did not read it.
String? packOf(String? readBy) {
  if (readBy == null) return null;
  final parts = readBy.trim().split(' ');
  if (parts.length < 2) return null;
  final at = parts[1].indexOf('@');
  final pack = at < 0 ? parts[1] : parts[1].substring(0, at);
  return pack.isEmpty ? null : pack;
}

/// Banks whose packs read a message about money reaching an M-Pesa wallet
/// from an account with them, and put it on M-Pesa (the pack's
/// `institution: mpesa` rules): KCB's "... received from MARY WAMBUI DOE -
/// 987****654 ... via KCB". Such a message is only a notice; M-Pesa's own
/// message for the same money is the wallet's record.
const walletNoticeBanks = {'kcb'};

/// Whether [receipt] is shaped as an M-Pesa receipt: ten letters and digits,
/// such as `TJA0000001`. Banks print longer references.
bool isMpesaReceipt(String? receipt) =>
    RegExp(r'^[A-Z0-9]{10}$').hasMatch(receipt?.trim().toUpperCase() ?? '');

/// Why two messages on one account are taken to be the same money.
enum TwinMatch {
  /// Both print the same reference.
  receipt,

  /// One prints a reference and the other, a plain account alert, does not.
  alert,

  /// Money from a bank account into M-Pesa, told by both: the bank's
  /// notice ("... received from JANE DOE - 123****890 via KCB") and
  /// M-Pesa's own message, which names the bank ("... You have received
  /// Ksh2,500.00 from KCB 1 522522") or the person who sent it. Each prints
  /// its own reference, so they never share one.
  walletCredit,
}

/// Whether [incoming], a new message on the same account as [stored], is
/// about the same money, and why; null when they are two transactions.
///
/// Both must be messages, the same way, the same amount and currency.
/// Then:
///
/// * both print a reference: the same money only when it is the same
///   reference, within [sameReceiptWindow]. Different references are
///   different payments, except for [TwinMatch.walletCredit]: money in
///   that a bank's pack read as a notice on M-Pesa (KCB's "received from
///   ... via KCB") and money M-Pesa's own message says was received from
///   the bank or the same sender ([walletCreditNamesAgree]), within
///   [twinWindow], and [stored] not already merged with another message;
/// * one prints a reference: the same money when they are within
///   [twinWindow], the one without is a plain alert (or the same kind), and
///   [stored] has not already taken a twin, so a second alert for the same
///   amount stays a payment of its own;
/// * neither prints one: never merged. Two plain alerts for the same amount
///   minutes apart are two payments.
TwinMatch? twinMatch(TwinFacts stored, TwinFacts incoming) {
  final storedHash = stored.messageHash;
  final incomingHash = incoming.messageHash;
  if (storedHash == null || incomingHash == null) return null;
  if (storedHash == incomingHash) return null;
  if (stored.direction != incoming.direction ||
      stored.amountMinor != incoming.amountMinor ||
      stored.currency != incoming.currency) {
    return null;
  }
  final gap = stored.at.difference(incoming.at).abs();
  final a = _reference(stored.receipt);
  final b = _reference(incoming.receipt);
  if (a != null && b != null) {
    if (a == b) return gap <= sameReceiptWindow ? TwinMatch.receipt : null;
    if (gap > twinWindow) return null;
    if (stored.twinHash != null && stored.twinHash != incomingHash) {
      return null;
    }
    final walletFirst = walletCreditSide(stored, incoming);
    if (walletFirst == null) return null;
    final (wallet, notice) = walletFirst
        ? (stored, incoming)
        : (incoming, stored);
    // M-Pesa names the bank or the same sender: one who is not the
    // notice's sender sent other money.
    return wallet.counterpartyName == null ||
            walletCreditNamesAgree(wallet, notice)
        ? TwinMatch.walletCredit
        : null;
  }
  if (a == null && b == null) return null;
  if (gap > twinWindow) return null;
  if (stored.twinHash != null && stored.twinHash != incomingHash) return null;
  final plain = a == null ? stored : incoming;
  final rich = a == null ? incoming : stored;
  if (plain.kind != TransactionKind.bank && plain.kind != rich.kind) {
    return null;
  }
  return TwinMatch.alert;
}

/// For two messages about money into M-Pesa from a bank account (see
/// [TwinMatch.walletCredit]): true when [first] is M-Pesa's own message
/// and [second] the bank's notice, false the other way, null when they are
/// not such a pair.
///
/// M-Pesa's message is money received that the M-Pesa pack read (or, read
/// before readers were recorded, that prints an M-Pesa receipt); the
/// notice is money in that a pack in [walletNoticeBanks] read. M-Pesa's
/// message names the bank ("from KCB 1 522522") or the sender; [twinMatch]
/// checks that name.
bool? walletCreditSide(TwinFacts first, TwinFacts second) {
  if (first.direction != TransactionDirection.inflow ||
      second.direction != TransactionDirection.inflow) {
    return null;
  }
  bool isWallet(TwinFacts f) =>
      f.kind == TransactionKind.received &&
      switch (packOf(f.readBy)) {
        'mpesa' => true,
        null => f.readBy == null && isMpesaReceipt(f.receipt),
        _ => false,
      };
  bool isNotice(TwinFacts f) =>
      walletNoticeBanks.contains(packOf(f.readBy)) &&
      (f.kind == TransactionKind.received || f.kind == TransactionKind.bank);

  if (isWallet(first) && isNotice(second)) return true;
  if (isWallet(second) && isNotice(first)) return false;
  return null;
}

/// Whether M-Pesa's message [wallet] and the bank's notice [notice] about
/// money into M-Pesa name the same sender, or M-Pesa names the bank: the
/// better pair when two M-Pesa messages of the same amount are near one
/// notice.
bool walletCreditNamesAgree(TwinFacts wallet, TwinFacts notice) {
  List<String> words(String? name) => [
    for (final w in (name ?? '').toUpperCase().split(RegExp(r'[^A-Z0-9*]+')))
      if (w.length > 1 && !w.contains('*') && !RegExp(r'^\d+$').hasMatch(w)) w,
  ];
  final printed = words(wallet.counterpartyName);
  if (printed.isEmpty) return false;
  if (printed.first == 'KCB') return true;
  return printed
      .toSet()
      .intersection(words(notice.counterpartyName).toSet())
      .isNotEmpty;
}

String? _reference(String? receipt) {
  final r = receipt?.trim().toUpperCase();
  return r == null || r.isEmpty ? null : r;
}

/// How far the rate a card payment and its account debit imply may be from
/// the day's rate for the two to be taken as one payment: 10%, room for a
/// bank's conversion margin and fees.
const cardRateToleranceBasisPoints = 1000;

/// Whether a card payment of [foreignMinor] in another currency and an
/// account debit of [accountMinor] in the account's currency, both shown in
/// the base currency as [foreignInBase] and [accountInBase], are about the
/// same money by amount: within [cardRateToleranceBasisPoints] of each
/// other.
bool cardAmountsAgree({
  required int foreignInBase,
  required int accountInBase,
}) {
  if (foreignInBase <= 0 || accountInBase <= 0) return false;
  final gap = (foreignInBase - accountInBase).abs();
  return gap * 10000 <= accountInBase * cardRateToleranceBasisPoints;
}
