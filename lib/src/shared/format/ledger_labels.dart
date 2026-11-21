import '../../domain/enums.dart';
import '../../domain/ledger/activity_lines.dart';
import '../../domain/ledger/ledger_entry.dart';

/// A plain name for an entry of [kind], for when nothing better is known.
String kindLabel(TransactionKind kind) => switch (kind) {
  TransactionKind.sent => 'Money sent',
  TransactionKind.received => 'Money received',
  TransactionKind.paybill => 'Paybill',
  TransactionKind.till => 'Buy Goods',
  TransactionKind.withdrawal => 'Cash withdrawal',
  TransactionKind.deposit => 'Cash deposit',
  TransactionKind.airtime => 'Airtime',
  TransactionKind.fulizaDraw => 'Fuliza',
  TransactionKind.fulizaRepayment => 'Fuliza repayment',
  TransactionKind.loanRepayment => 'Loan repayment',
  TransactionKind.roundUp => 'Round-up',
  TransactionKind.charge => 'Charge',
  TransactionKind.reversal => 'Reversal',
  TransactionKind.bank => 'Bank transaction',
  TransactionKind.correction => 'Balance correction',
};

/// The title of a day's [NoiseGroup] line.
String noiseTitle(NoiseGroup group) => switch (group) {
  NoiseGroup.fulizaDraws => 'Fuliza draws',
  NoiseGroup.fulizaRepayments => 'Fuliza repayments',
  NoiseGroup.roundUps => 'Round-ups to savings',
  NoiseGroup.charges => 'Charges',
  NoiseGroup.airtime => 'Airtime',
};

/// A cash book line's title: what it was for, then who with, such as
/// `Sale · Grace W.`; without a category, who with or what kind it was.
String cashBookTitle(LedgerEntry entry, {String? categoryName}) {
  final party = entry.payeeName ?? entry.counterpartyName ?? entry.note;
  final parts = [?categoryName, ?party];
  if (parts.isNotEmpty) return parts.join(' · ');
  return entry.counterpartyValue ?? kindLabel(entry.kind);
}

/// How a row names the account it moved through: its name, or for a
/// purchase with another space's money, "Paid from Vegetable stall"
/// (decision 0027, section 6). A row on Held for another space names the
/// account the money is on ([heldOn], "M-Pesa"), as the owner sees it.
String accountTag(String name, AccountType type, {String? heldOn}) =>
    switch (type) {
      AccountType.paidBySpace => 'Paid from $name',
      AccountType.heldForSpace => heldOn ?? name,
      _ => name,
    };
