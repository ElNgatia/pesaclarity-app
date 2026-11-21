import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../books/books.dart' show ownerPayCategoryKey;
import '../enums.dart';
import '../ledger/ledger_entry.dart';
import '../ledger/ledger_role.dart';

/// What Pesa Clarity sends to the person's own Firefly III (decision 0029,
/// section 2): each transaction as one or more Firefly III transactions,
/// worked out from the space's journal so every account there ends at the
/// balance it has here. Pure Dart: the sender turns these into requests.

/// The tag every sent transaction carries, beside its space's name.
const fireflyTag = 'pesaclarity';

/// The tag on money in from someone not named yet.
const fireflyToNameTag = 'pesaclarity-to-name';

/// The name used for a payee the person has not named yet.
const notNamedYet = 'Not named yet';

/// [spaceId] and [transactionId] as Firefly III's `external_id`, with the
/// [part] after a colon for a transaction sent as several:
/// `pesaclarity:personal:42`, `pesaclarity:personal:42:fee`.
String fireflyExternalId(
  String spaceId,
  int transactionId, [
  String part = '',
]) => part.isEmpty
    ? '$fireflyTag:$spaceId:$transactionId'
    : '$fireflyTag:$spaceId:$transactionId:$part';

/// The prefix every external id of [spaceId] starts with.
String fireflyExternalPrefix(String spaceId) => '$fireflyTag:$spaceId:';

/// A Firefly III account kind.
enum FireflyAccountKind { asset, liability, expense, revenue }

/// An account in Firefly III that Pesa Clarity sends to, by a [key] that
/// stays the same while its [name] may change.
class FireflyAccountSpec {
  const FireflyAccountSpec({
    required this.key,
    required this.kind,
    required this.name,
    this.role,
    this.currency,
    this.liabilityType,
  });

  /// One of the space's money accounts: `money:3`.
  factory FireflyAccountSpec.money({
    required int id,
    required String name,
    required String currency,
    required String role,
  }) => FireflyAccountSpec(
    key: 'money:$id',
    kind: FireflyAccountKind.asset,
    name: name,
    role: role,
    currency: currency,
  );

  /// Where payments go: an expense account named after the payee.
  factory FireflyAccountSpec.expense(String name) => FireflyAccountSpec(
    key: 'expense:$name',
    kind: FireflyAccountKind.expense,
    name: name,
  );

  /// Where money in comes from: a revenue account named after the payer.
  factory FireflyAccountSpec.revenue(String name) => FireflyAccountSpec(
    key: 'revenue:$name',
    kind: FireflyAccountKind.revenue,
    name: name,
  );

  /// Stable within the space: `money:3`, `fuliza:3`, `lender:M-Shwari`,
  /// `savings:KES`, `transit:KES`, `expense:Naivas`, `revenue:Employer`.
  /// Assets and liabilities are the space's own; expense and revenue
  /// accounts are shared by name across spaces.
  final String key;
  final FireflyAccountKind kind;
  final String name;

  /// `account_role` of an asset: `defaultAsset`, `cashWalletAsset` or
  /// `savingAsset`.
  final String? role;

  /// The currency of an asset or liability.
  final String? currency;

  /// `liability_type` of a liability: `loan` or `debt`. Every liability
  /// Pesa Clarity makes is owed by the person (`liability_direction`
  /// `debit`).
  final String? liabilityType;

  bool get isOwn =>
      kind == FireflyAccountKind.asset || kind == FireflyAccountKind.liability;

  Map<String, Object?> toJson() => {
    'key': key,
    'kind': kind.name,
    'name': name,
    'role': ?role,
    'currency': ?currency,
    'liability_type': ?liabilityType,
  };

  @override
  bool operator ==(Object other) =>
      other is FireflyAccountSpec &&
      other.key == key &&
      other.kind == kind &&
      other.name == name &&
      other.role == role &&
      other.currency == currency &&
      other.liabilityType == liabilityType;

  @override
  int get hashCode =>
      Object.hash(key, kind, name, role, currency, liabilityType);

  @override
  String toString() => 'FireflyAccountSpec($key, $name)';
}

/// Firefly III's three kinds of transaction.
enum FireflyPartType { withdrawal, deposit, transfer }

/// One Firefly III transaction (a group with one split) that a Pesa
/// Clarity transaction becomes. A transaction with a fee, or one the
/// journal reads more into, becomes several: Firefly III cannot mix a
/// transfer and a withdrawal in one group.
class FireflyPart {
  const FireflyPart({
    required this.suffix,
    required this.type,
    required this.at,
    required this.amountMinor,
    required this.currency,
    required this.source,
    required this.destination,
    required this.description,
    this.foreignAmountMinor,
    this.foreignCurrency,
    this.category,
    this.tags = const [],
    this.notes,
  }) : assert(amountMinor > 0, 'Firefly III takes positive amounts only');

  /// What follows the transaction's id in its external id: empty for the
  /// main part, then `fee`, `lost`, `repay`, `draw`, `adjust`, `owed` or
  /// `gap`.
  final String suffix;
  final FireflyPartType type;
  final DateTime at;

  /// In [currency], the currency of the asset or liability it moves.
  final int amountMinor;
  final String currency;

  /// What arrived in another currency, for a transfer across currencies.
  final int? foreignAmountMinor;
  final String? foreignCurrency;
  final FireflyAccountSpec source;
  final FireflyAccountSpec destination;
  final String description;
  final String? category;
  final List<String> tags;
  final String? notes;

  /// Every account it needs, source first.
  List<FireflyAccountSpec> get accounts => [source, destination];

  Map<String, Object?> toJson() => {
    'suffix': suffix,
    'type': type.name,
    'at': at.toUtc().toIso8601String(),
    'amount': amountMinor,
    'currency': currency,
    'foreign_amount': ?foreignAmountMinor,
    'foreign_currency': ?foreignCurrency,
    'source': source.toJson(),
    'destination': destination.toJson(),
    'description': description,
    'category': ?category,
    'tags': tags,
    'notes': ?notes,
  };

  @override
  String toString() =>
      'FireflyPart(${suffix.isEmpty ? 'main' : suffix} ${type.name} '
      '$amountMinor $currency ${source.key} -> ${destination.key})';
}

/// A hash of what [parts] say, kept with what was sent: when it changes,
/// the transaction is sent again.
String fireflyPartsHash(List<FireflyPart> parts) => sha256
    .convert(utf8.encode(jsonEncode([for (final p in parts) p.toJson()])))
    .toString();

/// One of the space's money accounts, as the mapping needs it.
class FireflyMoneyAccount {
  const FireflyMoneyAccount({
    required this.id,
    required this.name,
    required this.type,
    required this.currency,
    this.product,
    String? nameThere,
  }) : nameThere = nameThere ?? name;

  final int id;
  final String name;

  /// The name its account has in Firefly III: [name], told apart when two
  /// of the space's accounts share it, as Firefly III keeps one account
  /// per name.
  final String nameThere;
  final AccountType type;
  final String currency;

  /// The savings product it is, such as Chumz (0028).
  final String? product;

  /// Firefly III's `account_role` for it.
  String get role => switch (type) {
    AccountType.cash => 'cashWalletAsset',
    AccountType.sacco || AccountType.moneyMarket => 'savingAsset',
    _ when product != null => 'savingAsset',
    _ => 'defaultAsset',
  };

  /// Whether it can owe Fuliza: M-Pesa.
  bool get canOweFuliza => type == AccountType.mpesa;
}

/// How names read in Firefly III for one space. Spaces are tags in one
/// Firefly III user, and Firefly III keeps one account of each kind per
/// name, so a space's own accounts carry its name after Personal's.
class FireflyNames {
  const FireflyNames({required this.spaceName, required this.personal});

  final String spaceName;

  /// Personal's accounts keep their plain names.
  final bool personal;

  /// A name for one of this space's own accounts.
  String own(String name) => personal ? name : '$name · $spaceName';

  FireflyAccountSpec asset(FireflyMoneyAccount account) =>
      FireflyAccountSpec.money(
        id: account.id,
        name: own(account.nameThere),
        currency: account.currency,
        role: account.role,
      );

  /// Fuliza owed on M-Pesa [account].
  FireflyAccountSpec fuliza(FireflyMoneyAccount account) => FireflyAccountSpec(
    key: 'fuliza:${account.id}',
    kind: FireflyAccountKind.liability,
    name: own(
      account.name == 'M-Pesa' ? 'Fuliza' : 'Fuliza on ${account.name}',
    ),
    currency: account.currency,
    liabilityType: 'loan',
  );

  /// Money borrowed from [lender], such as M-Shwari.
  FireflyAccountSpec lender(String lender, String currency) =>
      FireflyAccountSpec(
        key: 'lender:$lender:$currency',
        kind: FireflyAccountKind.liability,
        name: own(currency == 'KES' ? lender : '$lender $currency'),
        currency: currency,
        liabilityType: 'loan',
      );

  /// Money put into savings held elsewhere.
  FireflyAccountSpec savings(String currency) => FireflyAccountSpec(
    key: 'savings:$currency',
    kind: FireflyAccountKind.asset,
    name: own(currency == 'KES' ? 'Savings' : 'Savings $currency'),
    role: 'savingAsset',
    currency: currency,
  );

  /// Money on its way between the space's accounts, until its other side
  /// arrives.
  FireflyAccountSpec transit(String currency) => FireflyAccountSpec(
    key: 'transit:$currency',
    kind: FireflyAccountKind.asset,
    name: own(
      currency == 'KES' ? 'Money in transit' : 'Money in transit $currency',
    ),
    role: 'defaultAsset',
    currency: currency,
  );
}

/// Labels of what the journal reads into a transaction beyond its own
/// amount.
const fireflyFees = 'Fees';
const fireflyFulizaCharges = 'Fuliza charges';
const fireflyNotYetSorted = 'Not yet sorted';
const fireflyBalanceCorrection = 'Balance correction';

/// What the mapping needs about one transaction.
class FireflyTransactionFacts {
  const FireflyTransactionFacts({
    required this.entry,
    required this.account,
    required this.journalMoneyMinor,
    this.journalFulizaMinor = 0,
    this.journalBorrowedMinor = 0,
    this.partner,
    this.partnerAccount,
    this.categoryName,
    this.categoryKey,
    this.receipt,
    this.tagNames = const [],
    this.gapMinor = 0,
  });

  final LedgerEntry entry;
  final FireflyMoneyAccount account;

  /// What the journal's entry for this transaction moves its money
  /// account by, with what Fuliza funded through Money in transit.
  final int journalMoneyMinor;

  /// What it moves the Fuliza owed on its account by: more owed is
  /// positive.
  final int journalFulizaMinor;

  /// What it moves other borrowed money by: more owed is positive.
  final int journalBorrowedMinor;

  /// The other side of the own transfer this is half of, when both are
  /// sent.
  final LedgerEntry? partner;
  final FireflyMoneyAccount? partnerAccount;
  final String? categoryName;
  final String? categoryKey;

  /// The M-Pesa code or bank reference.
  final String? receipt;
  final List<String> tagNames;

  /// What a balance the institution reported added beyond the records,
  /// on [account], posted to Not yet sorted.
  final int gapMinor;
}

/// The Firefly III transactions [facts] becomes, for a space named by
/// [names]. Empty for the money-in side of a matched own transfer: its
/// money-out side sends the transfer.
List<FireflyPart> fireflyParts(
  FireflyTransactionFacts facts,
  FireflyNames names,
) {
  final e = facts.entry;
  final role = roleOf(e);
  final asset = names.asset(facts.account);
  final currency = facts.account.currency;
  final parts = <FireflyPart>[];
  // What the parts move, by account key, to compare with the journal.
  final moved = <String, int>{};

  final payee = e.payeeName;
  final needsName = needsPayeeName(e);
  final tags = [
    fireflyTag,
    names.spaceName,
    ...facts.tagNames,
    if (needsName || role == LedgerRole.awaitingPayee) fireflyToNameTag,
  ];
  final notes = [
    if (facts.receipt case final r? when r.trim().isNotEmpty)
      '${facts.account.name} ${r.trim()}',
    if (role == LedgerRole.reversal) 'Reversal',
    if (e.note case final n? when n.trim().isNotEmpty) n.trim(),
  ].join('\n');

  void add(
    String suffix,
    FireflyPartType type,
    int amount,
    FireflyAccountSpec source,
    FireflyAccountSpec destination, {
    required String description,
    String? category,
    int? foreignAmount,
    String? foreignCurrency,
    int? destinationMoves,
  }) {
    if (amount <= 0) return;
    parts.add(
      FireflyPart(
        suffix: suffix,
        type: type,
        at: e.occurredAt,
        amountMinor: amount,
        currency: source.isOwn ? (source.currency ?? currency) : currency,
        foreignAmountMinor: foreignAmount,
        foreignCurrency: foreignCurrency,
        source: source,
        destination: destination,
        description: description,
        category: category,
        tags: tags,
        notes: notes.isEmpty ? null : notes,
      ),
    );
    // An asset goes down by what leaves it; a liability (owed) goes up by
    // what is taken from it.
    if (source.isOwn) {
      moved[source.key] =
          (moved[source.key] ?? 0) +
          (source.kind == FireflyAccountKind.asset ? -amount : amount);
    }
    if (destination.isOwn) {
      final arrives = destinationMoves ?? amount;
      moved[destination.key] =
          (moved[destination.key] ?? 0) +
          (destination.kind == FireflyAccountKind.asset ? arrives : -arrives);
    }
  }

  final name = payee ?? notNamedYet;
  final category = facts.categoryName;

  void spend(String to, {String? category, String suffix = ''}) => add(
    suffix,
    FireflyPartType.withdrawal,
    e.amountMinor,
    asset,
    FireflyAccountSpec.expense(to),
    description: to,
    category: category,
  );
  void earn(String from, {String? category}) => add(
    '',
    FireflyPartType.deposit,
    e.amountMinor,
    FireflyAccountSpec.revenue(from),
    asset,
    description: from,
    category: category,
  );

  final fuliza = facts.account.canOweFuliza
      ? names.fuliza(facts.account)
      : null;
  FireflyAccountSpec lender() =>
      names.lender(payee ?? e.counterpartyName ?? 'Borrowed', currency);
  final isFulizaKind =
      e.kind == TransactionKind.fulizaDraw ||
      e.kind == TransactionKind.fulizaRepayment;
  final debt = isFulizaKind && fuliza != null ? fuliza : null;

  switch (role) {
    case LedgerRole.correction || LedgerRole.betweenSpaces:
      // The journal says what it changed; it is sent as that below. Money
      // between spaces (decision 0027) is neither side's income or
      // spending: a correction of another space's part is sent as what it
      // moved, like any correction. Balance records are not transactions
      // and are never read as parts (see `readFireflySpace`).
      break;
    case LedgerRole.spending || LedgerRole.fee || LedgerRole.tax:
      final to = switch (role) {
        LedgerRole.fee => payee ?? fireflyFees,
        LedgerRole.tax => payee ?? 'Tax',
        _ => name,
      };
      final cat = category ?? (role == LedgerRole.fee ? fireflyFees : null);
      if (e.isOutflow) {
        spend(to, category: cat);
      } else {
        earn(to, category: cat);
      }
    case LedgerRole.income:
      if (e.isInflow) {
        earn(name, category: category);
      } else {
        spend(name, category: category);
      }
    case LedgerRole.awaitingPayee:
      earn(notNamedYet, category: category);
    case LedgerRole.reversal:
      if (e.isInflow) {
        earn(name, category: category);
      } else {
        spend(name, category: category);
      }
    case LedgerRole.borrowing:
      final from = debt ?? lender();
      if (e.isInflow) {
        add(
          '',
          FireflyPartType.deposit,
          e.amountMinor,
          from,
          asset,
          description: from.name,
          category: category,
        );
      } else {
        add(
          '',
          FireflyPartType.withdrawal,
          e.amountMinor,
          asset,
          from,
          description: from.name,
          category: category,
        );
      }
    case LedgerRole.debtRepayment:
      final to = debt ?? lender();
      if (e.isOutflow) {
        add(
          '',
          FireflyPartType.withdrawal,
          e.amountMinor,
          asset,
          to,
          description: to.name,
          category: category,
        );
      } else {
        add(
          '',
          FireflyPartType.deposit,
          e.amountMinor,
          to,
          asset,
          description: to.name,
          category: category,
        );
      }
    case LedgerRole.ownTransfer || LedgerRole.saving:
      final partner = facts.partner;
      final partnerAccount = facts.partnerAccount;
      if (partner != null && partnerAccount != null) {
        if (e.isInflow) {
          // The money out's side sends the transfer; this side arrived
          // with it.
          moved[asset.key] = (moved[asset.key] ?? 0) + e.amountMinor;
          break;
        }
        final into = names.asset(partnerAccount);
        final description = '${facts.account.name} to ${partnerAccount.name}';
        if (partner.currency != e.currency) {
          add(
            '',
            FireflyPartType.transfer,
            e.amountMinor,
            asset,
            into,
            description: description,
            foreignAmount: partner.amountMinor,
            foreignCurrency: partner.currency,
            destinationMoves: partner.amountMinor,
          );
        } else {
          final arrived = partner.amountMinor;
          final sent = e.amountMinor;
          add(
            '',
            FireflyPartType.transfer,
            arrived < sent ? arrived : sent,
            asset,
            into,
            description: description,
          );
          // Less arrived than left: the rest was a charge on the way. More
          // arrived: not yet explained.
          add(
            'lost',
            FireflyPartType.withdrawal,
            sent - arrived,
            asset,
            FireflyAccountSpec.expense(fireflyFees),
            description: 'Lost on the way',
            category: fireflyFees,
          );
          add(
            'lost',
            FireflyPartType.deposit,
            arrived - sent,
            FireflyAccountSpec.revenue(fireflyNotYetSorted),
            into,
            description: fireflyNotYetSorted,
            category: fireflyNotYetSorted,
          );
        }
        break;
      }
      // A business paying its owner leaves the books for good.
      if (e.isOutflow && facts.categoryKey == ownerPayCategoryKey) {
        spend(payee ?? category ?? 'Paid yourself', category: category);
        break;
      }
      final other = role == LedgerRole.saving
          ? names.savings(currency)
          : names.transit(currency);
      final description = role == LedgerRole.saving
          ? (payee ?? 'Saving')
          : 'Own transfer';
      if (e.isOutflow) {
        add(
          '',
          FireflyPartType.transfer,
          e.amountMinor,
          asset,
          other,
          description: description,
          category: role == LedgerRole.saving ? category : null,
        );
      } else {
        add(
          '',
          FireflyPartType.transfer,
          e.amountMinor,
          other,
          asset,
          description: description,
        );
      }
  }

  // The fee on top of the amount, as its own withdrawal to Fees. Fuliza's
  // access fee is added to what is owed, not taken from M-Pesa.
  if (e.feeMinor > 0) {
    if (e.kind == TransactionKind.fulizaDraw) {
      final owedTo = debt ?? lender();
      add(
        'fee',
        FireflyPartType.withdrawal,
        e.feeMinor,
        owedTo,
        FireflyAccountSpec.expense(fireflyFees),
        description: 'Fuliza access fee',
        category: fireflyFees,
      );
    } else {
      add(
        'fee',
        FireflyPartType.withdrawal,
        e.feeMinor,
        asset,
        FireflyAccountSpec.expense(fireflyFees),
        description: payee == null ? 'Transaction fee' : 'Fee · $payee',
        category: fireflyFees,
      );
    }
  }

  // What the journal reads into the transaction beyond its own amount and
  // fee: Fuliza's charges and repayments the balances show, what a reported
  // balance moved, a balance correction. Sent as it is, so the accounts in
  // Firefly III end where Pesa Clarity's do.
  final correction = role == LedgerRole.correction;
  var money = facts.journalMoneyMinor - (moved[asset.key] ?? 0);
  final borrowedFrom = lender();
  // Each liability once, with what the journal moved it by.
  final owedJournal = <String, (FireflyAccountSpec, int)>{};
  void owes(FireflyAccountSpec liability, int minor) {
    final (_, sum) = owedJournal[liability.key] ?? (liability, 0);
    owedJournal[liability.key] = (liability, sum + minor);
  }

  owes(fuliza ?? borrowedFrom, facts.journalFulizaMinor);
  owes(borrowedFrom, facts.journalBorrowedMinor);
  for (final p in parts) {
    for (final a in p.accounts) {
      if (a.kind == FireflyAccountKind.liability) owes(a, 0);
    }
  }
  var owedIndex = 0;
  for (final MapEntry(:key, value: (liability, journal))
      in owedJournal.entries) {
    var owed = journal - (moved[key] ?? 0);
    if (owed == 0) continue;
    final charges = isFulizaKind || key.startsWith('fuliza:');
    final label = correction
        ? fireflyBalanceCorrection
        : charges
        ? fireflyFulizaCharges
        : fireflyNotYetSorted;
    // Paid off from the account: a repayment the balances show.
    if (owed < 0 && money < 0) {
      final repaid = owed.abs() < money.abs() ? owed.abs() : money.abs();
      add(
        'repay',
        FireflyPartType.withdrawal,
        repaid,
        asset,
        liability,
        description: liability.name,
        category: correction ? fireflyBalanceCorrection : category,
      );
      owed += repaid;
      money += repaid;
    }
    // Borrowed into the account.
    if (owed > 0 && money > 0) {
      final drawn = owed < money ? owed : money;
      add(
        'draw',
        FireflyPartType.deposit,
        drawn,
        liability,
        asset,
        description: liability.name,
        category: correction ? fireflyBalanceCorrection : category,
      );
      owed -= drawn;
      money -= drawn;
    }
    final suffix = owedIndex == 0 ? 'owed' : 'owed$owedIndex';
    owedIndex++;
    if (owed > 0) {
      add(
        suffix,
        FireflyPartType.withdrawal,
        owed,
        liability,
        FireflyAccountSpec.expense(label),
        description: label,
        category: label,
      );
    } else if (owed < 0) {
      final from = correction ? fireflyBalanceCorrection : fireflyNotYetSorted;
      add(
        suffix,
        FireflyPartType.deposit,
        -owed,
        FireflyAccountSpec.revenue(from),
        liability,
        description: from,
        category: from,
      );
    }
  }
  final adjust = correction ? '' : 'adjust';
  if (money < 0) {
    final to = correction
        ? fireflyBalanceCorrection
        : isFulizaKind
        ? fireflyFulizaCharges
        : fireflyNotYetSorted;
    add(
      adjust,
      FireflyPartType.withdrawal,
      -money,
      asset,
      FireflyAccountSpec.expense(to),
      description: to,
      category: to,
    );
  } else if (money > 0) {
    final from = correction ? fireflyBalanceCorrection : fireflyNotYetSorted;
    add(
      adjust,
      FireflyPartType.deposit,
      money,
      FireflyAccountSpec.revenue(from),
      asset,
      description: from,
      category: from,
    );
  }

  // A balance the institution reported that the records did not reach.
  if (facts.gapMinor < 0) {
    add(
      'gap',
      FireflyPartType.withdrawal,
      -facts.gapMinor,
      asset,
      FireflyAccountSpec.expense(fireflyNotYetSorted),
      description: fireflyNotYetSorted,
      category: fireflyNotYetSorted,
    );
  } else if (facts.gapMinor > 0) {
    add(
      'gap',
      FireflyPartType.deposit,
      facts.gapMinor,
      FireflyAccountSpec.revenue(fireflyNotYetSorted),
      asset,
      description: fireflyNotYetSorted,
      category: fireflyNotYetSorted,
    );
  }
  return parts;
}

/// [minor] units of [currency] as Firefly III reads an amount: `450.00`.
String fireflyAmount(int minor, int digits) {
  final negative = minor < 0;
  final abs = minor.abs().toString().padLeft(digits + 1, '0');
  final whole = digits == 0 ? abs : abs.substring(0, abs.length - digits);
  final fraction = digits == 0 ? '' : '.${abs.substring(abs.length - digits)}';
  return '${negative ? '-' : ''}$whole$fraction';
}

/// A Firefly III amount such as `450.000000000000` as [digits] minor units,
/// rounded half away from zero; null when it is not a number.
int? fireflyMinor(String? amount, int digits) {
  if (amount == null) return null;
  final match = RegExp(r'^(-?)(\d+)(?:\.(\d+))?$').firstMatch(amount.trim());
  if (match == null) return null;
  final negative = match.group(1) == '-';
  final whole = BigInt.parse(match.group(2)!);
  final fraction = match.group(3) ?? '';
  final kept = fraction.padRight(digits + 1, '0');
  var minor =
      whole * BigInt.from(10).pow(digits) +
      BigInt.parse(digits == 0 ? '0' : kept.substring(0, digits));
  if (int.parse(kept[digits]) >= 5) minor += BigInt.one;
  final value = minor.toInt();
  return negative ? -value : value;
}

/// [at] as Firefly III's date, with the person's time zone [offset]:
/// `2026-11-03T14:05:00+03:00`.
String fireflyDate(DateTime at, Duration offset) {
  final local = at.toUtc().add(offset);
  String two(int n) => n.toString().padLeft(2, '0');
  final sign = offset.isNegative ? '-' : '+';
  final h = two(offset.inHours.abs());
  final m = two(offset.inMinutes.abs() % 60);
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
      '${two(local.day)}T${two(local.hour)}:${two(local.minute)}:'
      '${two(local.second)}$sign$h:$m';
}

/// What [parts] move each of the space's own Firefly III accounts by, by
/// key: an asset's balance, or what a liability says is owed.
Map<String, int> fireflyDeltas(Iterable<FireflyPart> parts) {
  final out = <String, int>{};
  for (final p in parts) {
    final source = p.source;
    if (source.isOwn) {
      out[source.key] =
          (out[source.key] ?? 0) +
          (source.kind == FireflyAccountKind.asset
              ? -p.amountMinor
              : p.amountMinor);
    }
    final into = p.destination;
    if (into.isOwn) {
      final arrives = p.foreignAmountMinor ?? p.amountMinor;
      out[into.key] =
          (out[into.key] ?? 0) +
          (into.kind == FireflyAccountKind.asset ? arrives : -arrives);
    }
  }
  return out;
}
