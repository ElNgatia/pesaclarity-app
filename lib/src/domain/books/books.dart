import '../../core/money/money.dart';
import '../enums.dart';
import '../ledger/balances.dart';
import '../ledger/ledger_entry.dart';
import '../ledger/ledger_role.dart';
import '../spaces/space_categories.dart';
import 'book_account.dart';
import 'journal.dart';

/// What a journal entry was made from.
enum JournalSource {
  /// A transaction: [JournalEntry.sourceId] is its id.
  transaction,

  /// An account's opening balance: [JournalEntry.sourceId] is the account id.
  opening,

  /// A balance the bank or M-Pesa reported that the records did not reach:
  /// [JournalEntry.sourceId] is the transaction that carried the balance, or
  /// the account id for the start of the account.
  balanceDifference,

  /// The part of a sale a customer pays later: [JournalEntry.sourceId] is
  /// the sale payment's id.
  creditSale,

  /// Stock or a cost bought to pay later: [JournalEntry.sourceId] is the
  /// record's id.
  creditPurchase,

  /// What a customer owed, or the business owed a supplier, before its
  /// records: [JournalEntry.sourceId] is the loan's or debt's id.
  owedBefore,

  /// Stock in at the start, sold, or counted: [JournalEntry.sourceId] is
  /// the stock move's id.
  stock,

  /// Tax a client kept back from a payment and paid to KRA for the
  /// business: [JournalEntry.sourceId] is the withheld record's id.
  withheld,

  /// One currency's half of an own transfer across currencies, posted when
  /// both sides are matched and dated when the money arrived:
  /// [JournalEntry.sourceId] is the transaction of the side in that
  /// currency.
  exchange,

  /// What a payment switched to another space left on its account where
  /// the account lives (decision 0027): [JournalEntry.sourceId] is the
  /// balance record's id.
  balanceRecord,

  /// In a business's books only, never stored in the journal: stock bought
  /// to sell, moved from what the transaction spent to stock, which is
  /// owned until it sells. [JournalEntry.sourceId] is the transaction's id.
  restock,
}

/// One line of a journal entry. Positive is a debit, negative a credit.
class JournalLine {
  const JournalLine(this.account, this.amountMinor);

  final BookAccount account;
  final int amountMinor;

  @override
  String toString() => 'JournalLine($account, $amountMinor)';
}

/// A balanced set of lines: debits equal credits.
class JournalEntry {
  JournalEntry({
    required this.source,
    required this.sourceId,
    required this.at,
    required this.currency,
    required Iterable<JournalLine> lines,
    this.memo,
    this.accountId,
  }) : lines = List.unmodifiable(lines.where((l) => l.amountMinor != 0));

  final JournalSource source;
  final int sourceId;
  final DateTime at;
  final String currency;
  final List<JournalLine> lines;

  /// Why the entry was made, when its source does not say.
  final String? memo;

  /// In a space's journal, the money account the entry belongs to: the
  /// account of its transaction, or the account it opens.
  final int? accountId;

  bool get isBalanced => lines.fold(0, (sum, l) => sum + l.amountMinor) == 0;

  @override
  String toString() => 'JournalEntry(${source.name} $sourceId, $lines)';
}

/// Category facts the posting needs, by category id.
typedef BookCategory = ({String? key, CategoryType type});

/// The part of a sale a customer pays later, as the books need it.
class CreditSale {
  const CreditSale({
    required this.paymentId,
    required this.at,
    required this.amountMinor,
    required this.currency,
    required this.salesCategoryId,
  });

  final int paymentId;
  final DateTime at;
  final int amountMinor;
  final String currency;

  /// The income category the sale counts under.
  final int salesCategoryId;
}

/// Stock or a cost bought to pay later, as the books need it.
class CreditPurchase {
  const CreditPurchase({
    required this.recordId,
    required this.at,
    required this.amountMinor,
    required this.currency,
    required this.categoryId,
    this.toStock = false,
  });

  final int recordId;
  final DateTime at;
  final int amountMinor;
  final String currency;

  /// The cost category it counts under.
  final int categoryId;

  /// Stock to sell, owned until it sells, rather than a cost.
  final bool toStock;
}

/// Money owed from before the records: by a customer to the business
/// ([toYou]), or by the business to a supplier.
class OwedBefore {
  const OwedBefore({
    required this.sourceId,
    required this.at,
    required this.amountMinor,
    required this.currency,
    required this.toYou,
  });

  final int sourceId;
  final DateTime at;
  final int amountMinor;
  final String currency;
  final bool toYou;
}

/// Tax a client withheld: it counts as tax paid and comes off what they
/// owe.
class WithheldTax {
  const WithheldTax({
    required this.sourceId,
    required this.at,
    required this.amountMinor,
    required this.currency,
  });

  final int sourceId;
  final DateTime at;
  final int amountMinor;
  final String currency;
}

/// A stock move the books post: stock there at the start, sold at the
/// average cost, or a count's difference.
class StockEntry {
  const StockEntry({
    required this.moveId,
    required this.at,
    required this.kind,
    required this.costMinor,
    required this.up,
    this.reason,
  });

  final int moveId;
  final DateTime at;
  final StockMoveKind kind;

  /// Always positive.
  final int costMinor;

  /// Whether stock went up.
  final bool up;
  final CountReason? reason;
}

/// Category key whose outflows are the owner taking money out.
const ownerPayCategoryKey = 'owner_pay';

/// Category key of the owner's own money put into a business (decision
/// 0027, Put money in): in the business, money in that is the owner's
/// capital, never owed back.
const ownerCapitalCategoryKey = 'owner_capital';

/// Category key of Personal's side of Put money in: money out of Personal
/// into one of the owner's businesses, never spending.
const putIntoBusinessCategoryKey = 'put_into_business';

/// A space's double-entry books: a view over its journal (decision 0018,
/// stage 4), with what only a business keeps on top. Nothing here is
/// stored: the books always follow the records.
///
/// The journal holds every transaction posted by its [LedgerRole], each
/// account's opening, and every reported balance as a check: what the
/// records do not reach stays in Not yet sorted until the person adds what
/// is missing or confirms a correction, so no plug keeps an account equal
/// to a figure. Fuliza is owed and charged as the balances show it, own
/// transfers clear through Money in transit with their fees, and money
/// between spaces posts as what it is (decision 0027).
///
/// On top of the journal: a sale on credit counts as a sale when it is
/// made, against what the customer owes, and their payment later clears
/// it; stock or a cost bought on credit works the same way with suppliers;
/// stock bought to sell is owned until it sells; what was owed from before
/// the records opens with the books; and tax a client withheld comes off
/// what they owe.
class Books {
  Books._(this.entries);

  /// The books of [journal], the space's journal entries (the stored
  /// journal in the app). Without it, the journal is posted from
  /// [history], [accounts] and [categories] as the app would store it
  /// ([postJournal]). [history] names the transactions in [restocks].
  factory Books.of(
    Iterable<LedgerEntry> history, {
    required Iterable<AccountOpening> accounts,
    required Map<int, BookCategory> categories,
    Iterable<JournalEntry>? journal,
    Iterable<CreditSale> credits = const [],
    Iterable<CreditPurchase> purchases = const [],
    Iterable<OwedBefore> owedBefore = const [],
    Iterable<StockEntry> stock = const [],
    Set<int> restocks = const {},
    Iterable<WithheldTax> withheld = const [],
  }) {
    final all = history.toList();
    final out = <JournalEntry>[
      ...journal ??
          postJournal(accounts: accounts, history: all, categories: categories),
    ];
    for (final e in all) {
      // Stock bought to sell is owned until it sells, not spent.
      if (!restocks.contains(e.id) || roleOf(e) != LedgerRole.spending) {
        continue;
      }
      final category = e.categoryId;
      final account = category != null && categories.containsKey(category)
          ? BookAccount.category(category, income: false)
          : BookAccount.uncategorisedSpending;
      final minor = e.isOutflow ? e.amountMinor : -e.amountMinor;
      out.add(
        JournalEntry(
          source: JournalSource.restock,
          sourceId: e.id,
          at: e.occurredAt,
          currency: e.currency,
          lines: [
            JournalLine(BookAccount.stock, minor),
            JournalLine(account, -minor),
          ],
        ),
      );
    }
    for (final m in stock) {
      out.add(_stockEntry(m));
    }
    for (final c in credits) {
      out.add(
        JournalEntry(
          source: JournalSource.creditSale,
          sourceId: c.paymentId,
          at: c.at,
          currency: c.currency,
          lines: [
            JournalLine(BookAccount.owedToYou, c.amountMinor),
            JournalLine(
              BookAccount.category(c.salesCategoryId, income: true),
              -c.amountMinor,
            ),
          ],
        ),
      );
    }
    // By time; at the same instant an opening comes first and a reported
    // balance's gap last, after the transaction that reported the balance.
    int rank(JournalSource s) => switch (s) {
      JournalSource.opening ||
      JournalSource.owedBefore ||
      JournalSource.stock => 0,
      JournalSource.transaction ||
      JournalSource.creditSale ||
      JournalSource.creditPurchase ||
      JournalSource.withheld ||
      JournalSource.exchange ||
      JournalSource.balanceRecord ||
      JournalSource.restock => 1,
      JournalSource.balanceDifference => 2,
    };
    for (final p in purchases) {
      out.add(
        JournalEntry(
          source: JournalSource.creditPurchase,
          sourceId: p.recordId,
          at: p.at,
          currency: p.currency,
          lines: [
            JournalLine(
              p.toStock
                  ? BookAccount.stock
                  : BookAccount.category(p.categoryId, income: false),
              p.amountMinor,
            ),
            JournalLine(BookAccount.owedToSuppliers, -p.amountMinor),
          ],
        ),
      );
    }
    for (final o in owedBefore) {
      final owed = o.toYou
          ? BookAccount.owedToYou
          : BookAccount.owedToSuppliers;
      final sign = o.toYou ? 1 : -1;
      out.add(
        JournalEntry(
          source: JournalSource.owedBefore,
          sourceId: o.sourceId,
          at: o.at,
          currency: o.currency,
          lines: [
            JournalLine(owed, sign * o.amountMinor),
            JournalLine(BookAccount.openingBalances, -sign * o.amountMinor),
          ],
        ),
      );
    }
    for (final w in withheld) {
      out.add(
        JournalEntry(
          source: JournalSource.withheld,
          sourceId: w.sourceId,
          at: w.at,
          currency: w.currency,
          lines: [
            JournalLine(BookAccount.tax, w.amountMinor),
            JournalLine(BookAccount.owedToYou, -w.amountMinor),
          ],
        ),
      );
    }
    out.sort((a, b) {
      final byTime = a.at.compareTo(b.at);
      return byTime != 0 ? byTime : rank(a.source).compareTo(rank(b.source));
    });
    return Books._(List.unmodifiable(out));
  }

  final List<JournalEntry> entries;

  /// Entries that do not balance. Empty unless something is wrong.
  List<JournalEntry> get unbalanced => [
    for (final e in entries)
      if (!e.isBalanced) e,
  ];

  /// The balance of [account] in [currency] from entries before [to] (and
  /// from [from], when given), positive in the account's normal direction:
  /// what an asset holds, what is owed, what was earned or spent.
  int balanceOf(
    BookAccount account, {
    required String currency,
    DateTime? from,
    DateTime? to,
  }) {
    var sum = 0;
    for (final e in entries) {
      if (e.currency != currency) continue;
      if (from != null && e.at.isBefore(from)) continue;
      if (to != null && !e.at.isBefore(to)) continue;
      for (final l in e.lines) {
        if (l.account == account) sum += l.amountMinor;
      }
    }
    return account.debitNormal ? sum : -sum;
  }

  /// Every account's debit-positive total in [currency] before [to]. Sums to
  /// zero when the books balance.
  Map<BookAccount, int> trialBalance({required String currency, DateTime? to}) {
    final out = <BookAccount, int>{};
    for (final e in entries) {
      if (e.currency != currency) continue;
      if (to != null && !e.at.isBefore(to)) continue;
      for (final l in e.lines) {
        out[l.account] = (out[l.account] ?? 0) + l.amountMinor;
      }
    }
    return out;
  }

  /// Total of [classOf] accounts in [currency] for entries in `[from, to)`.
  int totalOf(
    BookAccountClass classOf, {
    required String currency,
    required DateTime from,
    required DateTime to,
  }) {
    var sum = 0;
    for (final e in entries) {
      if (e.currency != currency || e.at.isBefore(from) || !e.at.isBefore(to)) {
        continue;
      }
      for (final l in e.lines) {
        if (l.account.accountClass == classOf) sum += l.amountMinor;
      }
    }
    final debitNormal =
        classOf == BookAccountClass.asset ||
        classOf == BookAccountClass.expense;
    return debitNormal ? sum : -sum;
  }

  /// Income less costs (spending, fees and tax) for `[from, to)`.
  int profit({
    required String currency,
    required DateTime from,
    required DateTime to,
  }) =>
      totalOf(BookAccountClass.income, currency: currency, from: from, to: to) -
      totalOf(BookAccountClass.expense, currency: currency, from: from, to: to);
}

/// Posts one stock move.
JournalEntry _stockEntry(StockEntry m) {
  final other = switch (m.kind) {
    StockMoveKind.opening => BookAccount.openingBalances,
    StockMoveKind.sold => BookAccount.costOfSales,
    StockMoveKind.counted when m.reason == CountReason.miscounted =>
      BookAccount.balanceDifferences,
    StockMoveKind.counted || StockMoveKind.restocked => BookAccount.stockLosses,
  };
  final cost = m.up ? m.costMinor : -m.costMinor;
  return JournalEntry(
    source: JournalSource.stock,
    sourceId: m.moveId,
    at: m.at,
    currency: BaseCurrency.code,
    lines: [JournalLine(BookAccount.stock, cost), JournalLine(other, -cost)],
  );
}

/// Posts one transaction by its own meaning, before what the journal reads
/// into it from the account's balances ([postJournal]).
JournalEntry postEntry(
  LedgerEntry e, {
  required Map<int, BookCategory> categories,
}) {
  final money = BookAccount.money(e.accountId);
  final amount = e.amountMinor;
  final category = e.categoryId == null ? null : categories[e.categoryId];
  final lines = <JournalLine>[];

  // Money moving: debit what it went to, credit the money account (out), or
  // the other way round (in).
  void outTo(BookAccount account, int minor) {
    lines
      ..add(JournalLine(account, minor))
      ..add(JournalLine(money, -minor));
  }

  void inFrom(BookAccount account, int minor) {
    lines
      ..add(JournalLine(money, minor))
      ..add(JournalLine(account, -minor));
  }

  BookAccount incomeAccount() => e.categoryId != null && category != null
      ? BookAccount.category(e.categoryId!, income: true)
      : BookAccount.uncategorisedIncome;
  BookAccount spendingAccount() => e.categoryId != null && category != null
      ? BookAccount.category(e.categoryId!, income: false)
      : BookAccount.uncategorisedSpending;

  // What a switched payment left where its account lives: the account and
  // Held for that space move together, its fee with it (decision 0027).
  if (e.heldForAccountId case final held?) {
    final heldFor = BookAccount.heldForSpace(held);
    e.isInflow ? inFrom(heldFor, amount) : outTo(heldFor, amount + e.feeMinor);
    return JournalEntry(
      source: JournalSource.balanceRecord,
      sourceId: e.balanceRecordId!,
      at: e.occurredAt,
      currency: e.currency,
      lines: lines,
    );
  }

  final ownerPay = category?.key == ownerPayCategoryKey;
  // Put money in (decision 0027): the owner's capital, on either side.
  final capital =
      (category?.key == ownerCapitalCategoryKey && e.isInflow) ||
      (category?.key == putIntoBusinessCategoryKey && e.isOutflow);
  final fromCustomer = category?.key == customerPaymentsKey;
  final toSupplier = category?.key == supplierPaymentsKey;
  switch (roleOf(e)) {
    case LedgerRole.income when fromCustomer:
      e.isInflow
          ? inFrom(BookAccount.owedToYou, amount)
          : outTo(BookAccount.owedToYou, amount);
    case LedgerRole.income:
      e.isInflow
          ? inFrom(incomeAccount(), amount)
          : outTo(incomeAccount(), amount);
    case LedgerRole.spending:
      e.isOutflow
          ? outTo(spendingAccount(), amount)
          : inFrom(spendingAccount(), amount);
    case LedgerRole.fee:
      outTo(BookAccount.fees, amount);
    case LedgerRole.tax:
      outTo(BookAccount.tax, amount);
    case LedgerRole.saving:
      outTo(BookAccount.savings, amount);
    case LedgerRole.borrowing:
      e.isInflow
          ? inFrom(BookAccount.borrowed, amount)
          : outTo(BookAccount.borrowed, amount);
    case LedgerRole.debtRepayment when toSupplier:
      e.isOutflow
          ? outTo(BookAccount.owedToSuppliers, amount)
          : inFrom(BookAccount.owedToSuppliers, amount);
    case LedgerRole.debtRepayment:
      if (e.isInflow) {
        // Not seen in real messages, but kept balanced: money back from a
        // lender adds to what is owed.
        inFrom(BookAccount.borrowed, amount);
      } else {
        outTo(BookAccount.borrowed, amount);
      }
    case LedgerRole.awaitingPayee:
      inFrom(BookAccount.awaitingPayee, amount);
    case LedgerRole.lending:
      // Money lent is still the person's, owed back to them: it moves
      // Owed to you, as a customer's credit does in a business.
      e.isOutflow
          ? outTo(BookAccount.owedToYou, amount)
          : inFrom(BookAccount.owedToYou, amount);
    case LedgerRole.ownTransfer:
      final other = ownerPay && e.isOutflow
          ? BookAccount.ownerPay
          : capital
          ? BookAccount.ownerCapital
          : BookAccount.ownTransfers;
      e.isInflow ? inFrom(other, amount) : outTo(other, amount);
    case LedgerRole.correction:
      e.isInflow
          ? inFrom(BookAccount.balanceCorrections, amount)
          : outTo(BookAccount.balanceCorrections, amount);
    case LedgerRole.betweenSpaces:
      // Another space's part set right: a balance correction on each side.
      e.isInflow
          ? inFrom(BookAccount.balanceCorrections, amount)
          : outTo(BookAccount.balanceCorrections, amount);
    case LedgerRole.reversal:
      // A refund in takes spending back; money sent back takes income back.
      e.isInflow
          ? inFrom(spendingAccount(), amount)
          : outTo(incomeAccount(), amount);
  }
  if (e.feeMinor > 0 && e.kind == TransactionKind.fulizaDraw) {
    // Fuliza's access fee is added to what is owed, not taken from M-Pesa.
    lines
      ..add(JournalLine(BookAccount.fees, e.feeMinor))
      ..add(JournalLine(BookAccount.borrowed, -e.feeMinor));
  } else if (e.feeMinor > 0) {
    outTo(BookAccount.fees, e.feeMinor);
  }

  return JournalEntry(
    source: JournalSource.transaction,
    sourceId: e.id,
    at: e.occurredAt,
    currency: e.currency,
    lines: lines,
  );
}
