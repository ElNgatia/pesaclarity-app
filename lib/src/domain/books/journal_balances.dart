import '../ledger/balances.dart';
import '../ledger/ledger_entry.dart';
import 'book_account.dart';
import 'books.dart';
import 'journal.dart';

/// What one transaction did by the postings of its journal entry
/// (decision 0018, stage 4): the figures Plan, Insights, Activity, reports
/// and tax count it for. Each is positive in the account's normal
/// direction, so a refund is negative spending and money sent back is
/// negative income. Reversals and the entries they cancel net out, so only
/// what the entry says now counts.
class PostedParts {
  const PostedParts({
    this.incomeMinor = 0,
    this.spendingMinor = 0,
    this.feesMinor = 0,
    this.fulizaChargesMinor = 0,
    this.taxMinor = 0,
    this.savingMinor = 0,
  });

  /// Reads one transaction's net postings, by account.
  factory PostedParts.of(Map<BookAccount, int> lines) {
    var income = 0;
    var spending = 0;
    var fees = 0;
    var charges = 0;
    var tax = 0;
    var saving = 0;
    for (final MapEntry(key: account, value: amount) in lines.entries) {
      switch (account.kind) {
        case BookAccountKind.incomeCategory ||
            BookAccountKind.uncategorisedIncome:
          income -= amount;
        case BookAccountKind.spendingCategory ||
            BookAccountKind.uncategorisedSpending:
          spending += amount;
        case BookAccountKind.fees:
          fees += amount;
        case BookAccountKind.fulizaCharges:
          charges += amount;
        case BookAccountKind.tax:
          tax += amount;
        case BookAccountKind.savings:
          saving += amount;
        case _:
          break;
      }
    }
    return PostedParts(
      incomeMinor: income,
      spendingMinor: spending,
      feesMinor: fees,
      fulizaChargesMinor: charges,
      taxMinor: tax,
      savingMinor: saving,
    );
  }

  /// Income, net of money sent back.
  final int incomeMinor;

  /// Spending on its category (or Uncategorised), net of refunds.
  final int spendingMinor;

  /// Transaction costs and charges, without Fuliza's.
  final int feesMinor;

  /// What Fuliza charged in this entry: access fees, daily charges, and
  /// what a repayment took beyond what was owed.
  final int fulizaChargesMinor;
  final int taxMinor;

  /// Money put into savings held elsewhere.
  final int savingMinor;

  /// Every fee and charge, Fuliza's included.
  int get allFeesMinor => feesMinor + fulizaChargesMinor;
}

/// Balances read from a space's journal (decision 0018, stage 2): every
/// figure is a sum of postings. Built from the stored journal in the app,
/// or from the records with [JournalBalances.ofRecords].
class JournalBalances {
  /// Reads [entries], in any order. [posted] adds transactions the journal
  /// posted with no postings, which a stored journal keeps as entries
  /// without lines.
  JournalBalances(Iterable<JournalEntry> entries, {Set<int> posted = const {}})
    : _posted = {...posted} {
    for (final e in entries) {
      if (e.source == JournalSource.transaction) _posted.add(e.sourceId);
      final own = e.source == JournalSource.transaction
          ? _byTransaction[(e.sourceId, e.currency)] ??= {}
          : null;
      for (final l in e.lines) {
        (_lines[(l.account, e.currency)] ??= []).add((e.at, l.amountMinor));
        if (own != null) own[l.account] = (own[l.account] ?? 0) + l.amountMinor;
      }
    }
    for (final list in _lines.values) {
      list.sort((a, b) => a.$1.compareTo(b.$1));
      var sum = 0;
      final sums = <int>[];
      for (final (_, amount) in list) {
        sums.add(sum += amount);
      }
      _running[list] = sums;
    }
  }

  /// The journal [postJournal] makes of the records, without storing it.
  factory JournalBalances.ofRecords(
    Iterable<AccountOpening> accounts,
    Iterable<LedgerEntry> history, {
    Map<int, BookCategory> categories = const {},
  }) => JournalBalances(
    postJournal(accounts: accounts, history: history, categories: categories),
  );

  final _lines = <(BookAccount, String), List<(DateTime, int)>>{};
  final _running = Expando<List<int>>();

  /// Each transaction's net postings by account, by its id and currency.
  final _byTransaction = <(int, String), Map<BookAccount, int>>{};
  final _parts = <(int, String), PostedParts>{};

  /// The transactions the journal has an entry for, lines or not.
  final Set<int> _posted;

  /// What transaction [e] did by its entry's postings, in [e]'s currency;
  /// null when the journal has no entry for it (not posted yet, or a
  /// journal of other records). An entry that posted nothing, such as a
  /// Fuliza repayment whose money in already paid what was owed, did
  /// nothing.
  PostedParts? partsOf(LedgerEntry e) {
    if (e.isBalanceRecord || !_posted.contains(e.id)) return null;
    final key = (e.id, e.currency);
    final known = _parts[key];
    if (known != null) return known;
    return _parts[key] = PostedParts.of(_byTransaction[key] ?? const {});
  }

  /// Debit-positive total of [account] in [currency] from postings dated
  /// before [at], or all of them.
  int _debits(BookAccount account, String currency, DateTime? at) {
    final list = _lines[(account, currency)];
    if (list == null || list.isEmpty) return 0;
    final sums = _running[list]!;
    if (at == null) return sums.last;
    // The last posting dated before [at].
    var lo = 0;
    var hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].$1.isBefore(at)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo == 0 ? 0 : sums[lo - 1];
  }

  /// [account]'s balance in [currency] just before [at] (or after every
  /// posting), positive in its normal direction: what an asset holds, what
  /// is owed, what was earned or spent.
  int balanceOf(BookAccount account, {required String currency, DateTime? at}) {
    final debits = _debits(account, currency, at);
    return account.debitNormal ? debits : -debits;
  }

  /// What [account] moved by in `[from, to)`, in its normal direction.
  int flowOf(
    BookAccount account, {
    required String currency,
    required DateTime from,
    required DateTime to,
  }) =>
      balanceOf(account, currency: currency, at: to) -
      balanceOf(account, currency: currency, at: from);

  /// The money in [account] just before [at]: for M-Pesa, the wallet,
  /// before any Fuliza owed.
  int walletAt(AccountOpening account, {required DateTime at}) => balanceOf(
    BookAccount.money(account.id),
    currency: account.currency,
    at: at,
  );

  /// Fuliza owed on [account] just before [at]; nothing for accounts that
  /// cannot owe Fuliza.
  int fulizaOwedAt(AccountOpening account, {required DateTime at}) =>
      account.canOweFuliza
      ? balanceOf(
          BookAccount.fulizaOwed(account.id),
          currency: account.currency,
          at: at,
        )
      : 0;

  /// What [account] is really worth just before [at]: its money less any
  /// Fuliza owed. The figure Balances and On hand show.
  int heldAt(AccountOpening account, {required DateTime at}) =>
      walletAt(account, at: at) - fulizaOwedAt(account, at: at);

  /// The money in the [accounts] that pass [where] just before [at].
  int totalWalletAt(
    Iterable<AccountOpening> accounts, {
    required DateTime at,
    required bool Function(AccountOpening account) where,
  }) => accounts.where(where).fold(0, (sum, a) => sum + walletAt(a, at: at));

  /// What the [accounts] that pass [where] are really worth just before
  /// [at], Fuliza owed taken off.
  int totalHeldAt(
    Iterable<AccountOpening> accounts, {
    required DateTime at,
    required bool Function(AccountOpening account) where,
  }) => accounts.where(where).fold(0, (sum, a) => sum + heldAt(a, at: at));
}
