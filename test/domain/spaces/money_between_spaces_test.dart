// The worked examples of decision 0027 (money on one account that belongs
// to another space), posted through each space's own journal. Every figure
// is checked in both spaces, and the two always add up to what the wallet
// holds: nothing counted twice and nothing lost. Made-up numbers only.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/books/book_account.dart';
import 'package:pesaclarity/src/domain/books/books.dart';
import 'package:pesaclarity/src/domain/books/business_report.dart';
import 'package:pesaclarity/src/domain/books/journal.dart';
import 'package:pesaclarity/src/domain/books/journal_balances.dart';
import 'package:pesaclarity/src/domain/enums.dart';
import 'package:pesaclarity/src/domain/ledger/balances.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_entry.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_role.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_totals.dart';
import 'package:pesaclarity/src/domain/spaces/money_between_spaces.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';

import '../fixtures.dart';

const stall = 'stall';
const personal = 'personal';

// Personal: its M-Pesa (1), Held for Vegetable stall on it (2), Paid by
// Vegetable stall (3). Categories: Food 1, Salary from my business 2,
// Family 3.
final start = eat(2026, 11, 1, 0);
final personalAccounts = [
  AccountOpening(
    id: 1,
    type: AccountType.mpesa,
    openingBalanceMinor: kes(37819),
    openingDate: start,
  ),
  AccountOpening(
    id: 2,
    type: AccountType.heldForSpace,
    openingBalanceMinor: 0,
    openingDate: start,
  ),
  AccountOpening(
    id: 3,
    type: AccountType.paidBySpace,
    openingBalanceMinor: 0,
    openingDate: start,
  ),
];
const personalCategories = <int, BookCategory>{
  1: (key: 'food', type: CategoryType.expense),
  2: (key: 'pay_from_business', type: CategoryType.income),
  3: (key: 'family', type: CategoryType.expense),
};

// Vegetable stall: Cash (1), KCB (2), the owner's account on Personal's
// M-Pesa (3). Categories: Sales 10, Stock and supplies 11, Paid yourself
// 12, Staff meals 13.
final stallAccounts = [
  AccountOpening(
    id: 1,
    type: AccountType.cash,
    openingBalanceMinor: kes(2000),
    openingDate: start,
  ),
  AccountOpening(
    id: 2,
    type: AccountType.bank,
    openingBalanceMinor: kes(10000),
    openingDate: start,
  ),
  AccountOpening(
    id: 3,
    type: AccountType.ownersAccount,
    openingBalanceMinor: 0,
    openingDate: start,
  ),
];
const stallCategories = <int, BookCategory>{
  10: (key: 'sales', type: CategoryType.income),
  11: (key: 'stock', type: CategoryType.expense),
  12: (key: 'owner_pay', type: CategoryType.transfer),
  13: (key: 'staff_meals', type: CategoryType.expense),
};

const held = BetweenSpacesAccount(
  id: 2,
  type: AccountType.heldForSpace,
  spaceId: stall,
  accountId: 1,
  currency: 'KES',
);
const owners = BetweenSpacesAccount(
  id: 3,
  type: AccountType.ownersAccount,
  spaceId: personal,
  accountId: 1,
  currency: 'KES',
);

LedgerEntry tx(
  int id,
  int account,
  DateTime at,
  int amount, {
  bool inflow = false,
  int? category,
  CategoryType? type,
  int? balance,
  TransactionKind kind = TransactionKind.sent,
  String? linked,
}) => LedgerEntry(
  id: id,
  accountId: account,
  occurredAt: at,
  amountMinor: amount,
  direction: inflow
      ? TransactionDirection.inflow
      : TransactionDirection.outflow,
  kind: kind,
  categoryId: category,
  categoryType:
      type ?? {...personalCategories, ...stallCategories}[category]?.type,
  payeeId: category == null ? null : 1,
  balanceAfterMinor: balance,
  linkedSpaceId: linked,
);

/// What a switched payment leaves on Personal's M-Pesa.
LedgerEntry record(
  int recordId,
  DateTime at,
  int amount, {
  bool inflow = false,
  int? balance,
}) => LedgerEntry(
  id: -recordId,
  accountId: 1,
  occurredAt: at,
  amountMinor: amount,
  direction: inflow
      ? TransactionDirection.inflow
      : TransactionDirection.outflow,
  kind: inflow ? TransactionKind.received : TransactionKind.paybill,
  balanceAfterMinor: balance,
  linkedSpaceId: stall,
  heldForAccountId: 2,
);

/// One space's records and the figures the app shows from them.
class Space {
  Space(this.accounts, this.categories);

  final List<AccountOpening> accounts;
  final Map<int, BookCategory> categories;
  final history = <LedgerEntry>[];

  List<JournalEntry> get journal =>
      postJournal(accounts: accounts, history: history, categories: categories);

  JournalBalances get balances => JournalBalances(journal);

  int money(int accountId) =>
      balances.balanceOf(BookAccount.money(accountId), currency: 'KES');

  MoneyBetweenSpaces get between => MoneyBetweenSpaces.of(
    accounts.first.type == AccountType.mpesa ? [held] : [owners],
    balances,
  );

  /// What lists, totals and reports read: transactions only.
  List<LedgerEntry> get transactions => [
    for (final e in history)
      if (!e.isBalanceRecord) e,
  ];

  LedgerTotals get totals => LedgerTotals.of(
    transactions,
    from: start,
    to: eat(2026, 12, 1),
    currency: 'KES',
  );

  int get moneyIn => totals.moneyInMinor;
  int get moneyOut => totals.spendingMinor;

  int classTotal(BookAccountClass c) {
    var sum = 0;
    for (final e in journal) {
      for (final l in e.lines) {
        if (l.account.accountClass == c) sum += l.amountMinor;
      }
    }
    return sum;
  }

  /// Income less costs, from the journal.
  int get profit =>
      -classTotal(BookAccountClass.income) -
      classTotal(BookAccountClass.expense);

  /// What the owner took: Paid yourself, an equity account the owner's
  /// drawings debit.
  int get paidYourself =>
      -balances.balanceOf(BookAccount.ownerPay, currency: 'KES');

  int get notYetSorted =>
      balances.balanceOf(BookAccount.notYetSorted, currency: 'KES');

  /// The space's own accounts, as On hand and Balances add them up.
  int get ownAccounts => [
    for (final a in accounts)
      if (!a.type.isBetweenSpaces) balances.heldAt(a, at: eat(2100, 1, 1)),
  ].fold(0, (s, v) => s + v);
}

void expectBooksSound(Space s) {
  for (final e in s.journal) {
    expect(e.isBalanced, isTrue, reason: '$e');
  }
  expect(s.notYetSorted, 0, reason: 'every reported balance reconciles');
}

void main() {
  late Space p;
  late Space b;
  setUp(() {
    p = Space(personalAccounts, personalCategories);
    b = Space(stallAccounts, stallCategories);
  });

  void sale(int id, DateTime at, int amount, int wallet) {
    p.history.add(record(id, at, amount, inflow: true, balance: wallet));
    b.history.add(
      tx(
        id,
        3,
        at,
        amount,
        inflow: true,
        category: 10,
        type: CategoryType.income,
        linked: personal,
      ),
    );
  }

  void cost(int id, DateTime at, int amount, int wallet) {
    p.history.add(record(id, at, amount, balance: wallet));
    b.history.add(
      tx(
        id,
        3,
        at,
        amount,
        category: 11,
        type: CategoryType.expense,
        linked: personal,
      ),
    );
  }

  void payYourselfOnLine(int id, DateTime at, int amount) {
    p.history.add(
      tx(
        id,
        2,
        at,
        amount,
        inflow: true,
        category: 2,
        type: CategoryType.income,
        linked: stall,
      ),
    );
    b.history.add(
      tx(
        id,
        3,
        at,
        amount,
        category: 12,
        type: CategoryType.transfer,
        linked: personal,
      ),
    );
  }

  group('section 3: the owner\'s M-Pesa, used for both', () {
    test('step 1: a KES 650 sale', () {
      sale(1, eat(2026, 11, 20, 17, 6), kes(650), kes(38469));
      expect(p.money(1), kes(38469));
      expect(p.between.heldFor(stall), kes(650));
      expect(p.moneyIn, 0);
      expect(p.transactions, isEmpty, reason: 'no row in Personal');
      expect(b.between.onAccountsOf(personal), kes(650));
      expect(b.totals.incomeMinor, kes(650));
      expect(b.profit, kes(650));
      expect(
        p.money(1) -
            p.between.heldFor(stall) +
            b.between.onAccountsOf(personal),
        kes(38469),
        reason: "37,819 the owner's + 650 the stall's",
      );
      expectBooksSound(p);
      expectBooksSound(b);
    });

    test('step 2: a KES 400 supplier from the line', () {
      sale(1, eat(2026, 11, 20, 17, 6), kes(650), kes(38469));
      cost(2, eat(2026, 11, 20, 18, 20), kes(400), kes(38069));
      expect(p.money(1), kes(38069));
      expect(p.between.heldFor(stall), kes(250));
      expect(p.moneyOut, 0);
      expect(b.between.onAccountsOf(personal), kes(250));
      expect(b.profit, kes(250));
      expectBooksSound(p);
      expectBooksSound(b);
    });

    test('step 3: Pay yourself KES 200 on the same line', () {
      sale(1, eat(2026, 11, 20, 17, 6), kes(650), kes(38469));
      cost(2, eat(2026, 11, 20, 18, 20), kes(400), kes(38069));
      payYourselfOnLine(3, eat(2026, 11, 21, 9), kes(200));
      expect(p.money(1), kes(38069), reason: 'no money moves');
      expect(p.between.heldFor(stall), kes(50));
      expect(p.totals.incomeMinor, kes(200), reason: 'Salary from my business');
      expect(b.paidYourself, kes(200));
      expect(b.between.onAccountsOf(personal), kes(50));
      expect(b.profit, kes(250), reason: 'pay is never a cost');
      expect(p.money(1) - p.between.heldFor(stall), kes(38019));
      expectBooksSound(p);
      expectBooksSound(b);
    });

    test('step 4: Pay yourself KES 2,500 from the KCB into the M-Pesa', () {
      sale(1, eat(2026, 11, 20, 17, 6), kes(650), kes(38469));
      cost(2, eat(2026, 11, 20, 18, 20), kes(400), kes(38069));
      payYourselfOnLine(3, eat(2026, 11, 21, 9), kes(200));
      // Real money moves: each space reads its own message.
      p.history.add(
        tx(
          4,
          1,
          eat(2026, 11, 21, 10),
          kes(2500),
          inflow: true,
          category: 2,
          type: CategoryType.income,
          balance: kes(40569),
          kind: TransactionKind.received,
        ),
      );
      b.history.add(
        tx(
          4,
          2,
          eat(2026, 11, 21, 10),
          kes(2500),
          category: 12,
          type: CategoryType.transfer,
          kind: TransactionKind.bank,
        ),
      );
      expect(p.money(1), kes(40569));
      expect(p.between.heldFor(stall), kes(50));
      expect(p.totals.incomeMinor, kes(2700));
      expect(b.money(2), kes(7500));
      expect(b.paidYourself, kes(2700));
      expect(b.between.onAccountsOf(personal), kes(50));
      expect(b.profit, kes(250));
      expect(p.money(1) - p.between.heldFor(stall), kes(40519));
      expectBooksSound(p);
      expectBooksSound(b);
    });

    test('a KES 1,000 cost instead: the stall owes the owner KES 350', () {
      sale(1, eat(2026, 11, 20, 17, 6), kes(650), kes(38469));
      cost(2, eat(2026, 11, 20, 18, 20), kes(1000), kes(37469));
      expect(p.money(1), kes(37469));
      expect(p.between.heldFor(stall), -kes(350));
      expect(p.between.notOwnMinor, 0, reason: 'owed is not spendable');
      expect(b.between.onAccountsOf(personal), -kes(350));
      expect(b.between.putInMinor, kes(350));
      expect(b.between.ownersMoneyMinor, 0, reason: 'not money it has');
      expectBooksSound(p);
      expectBooksSound(b);
    });

    test("step 5: setting the stall's part leaves the wallet alone", () {
      sale(1, eat(2026, 11, 20, 17, 6), kes(650), kes(38469));
      cost(2, eat(2026, 11, 20, 18, 20), kes(400), kes(38069));
      payYourselfOnLine(3, eat(2026, 11, 21, 9), kes(200));
      // The owner knows KES 300 of the wallet is the stall's, not 50.
      p.history.add(
        tx(
          5,
          2,
          eat(2026, 11, 21, 11),
          kes(250),
          kind: TransactionKind.correction,
          linked: stall,
        ),
      );
      b.history.add(
        tx(
          5,
          3,
          eat(2026, 11, 21, 11),
          kes(250),
          inflow: true,
          kind: TransactionKind.correction,
          linked: personal,
        ),
      );
      expect(p.money(1), kes(38069));
      expect(p.between.heldFor(stall), kes(300));
      expect(b.between.onAccountsOf(personal), kes(300));
      expect(p.moneyIn, kes(200), reason: "only step 3's pay");
      expect(p.moneyOut, 0);
      expect(b.profit, kes(250), reason: 'a correction is no sale');
      for (final s in [p, b]) {
        expect(
          s.transactions.where((e) => e.id == 5).map(roleOf).single,
          LedgerRole.betweenSpaces,
        );
      }
      expectBooksSound(p);
      expectBooksSound(b);
    });

    test('step 6: an old cost switched to the stall', () {
      // 3 September, KES 4,000 to Example Suppliers, spent in Personal.
      final sept = eat(2026, 9, 3);
      final accounts = [
        AccountOpening(
          id: 1,
          type: AccountType.mpesa,
          openingBalanceMinor: kes(41819),
          openingDate: eat(2026, 9, 1),
        ),
        ...personalAccounts.skip(1),
      ];
      p = Space(accounts, personalCategories);
      final paid = tx(
        9,
        1,
        sept,
        kes(4000),
        category: 3,
        type: CategoryType.expense,
        balance: kes(37819),
        kind: TransactionKind.paybill,
      );
      p.history.add(paid);
      final septTotals = LedgerTotals.of(
        p.transactions,
        from: eat(2026, 9, 1),
        to: eat(2026, 10, 1),
        currency: 'KES',
      );
      expect(septTotals.spendingMinor, kes(4000));
      // Switched: Personal keeps only its balance record.
      p.history
        ..remove(paid)
        ..add(record(9, sept, kes(4000), balance: kes(37819)));
      b.history.add(
        tx(
          9,
          3,
          sept,
          kes(4000),
          category: 11,
          type: CategoryType.expense,
          linked: personal,
        ),
      );
      final after = LedgerTotals.of(
        p.transactions,
        from: eat(2026, 9, 1),
        to: eat(2026, 10, 1),
        currency: 'KES',
      );
      expect(after.spendingMinor, 0);
      expect(p.money(1), kes(37819), reason: "September's balances add up");
      expect(b.profit, -kes(4000));
      expect(p.between.heldFor(stall), -kes(4000));
      expectBooksSound(p);
      expectBooksSound(b);
    });
  });

  group("section 4: one line with the business's own channels", () {
    test('a Pochi sale, a till sale and a payment to a friend', () {
      sale(1, eat(2026, 11, 20, 9), kes(650), kes(38469));
      sale(2, eat(2026, 11, 20, 11), kes(1200), kes(39669));
      p.history.add(
        tx(
          3,
          1,
          eat(2026, 11, 20, 13),
          kes(500),
          category: 3,
          type: CategoryType.expense,
          balance: kes(39169),
        ),
      );
      expect(p.money(1), kes(39169));
      expect(p.between.heldFor(stall), kes(1850));
      expect(p.moneyIn, 0);
      expect(p.moneyOut, kes(500));
      expect(p.transactions, hasLength(1), reason: 'only the friend');
      expect(
        p.ownAccounts - p.between.notOwnMinor,
        kes(37319),
        reason: 'safe to spend is worked from the rest',
      );
      expect(b.between.onAccountsOf(personal), kes(1850));
      expect(b.totals.incomeMinor, kes(1850));
      expect(b.profit, kes(1850));
      expect(
        p.ownAccounts - p.between.notOwnMinor + b.between.ownersMoneyMinor,
        kes(39169),
        reason: 'together, what the wallet holds',
      );
      expectBooksSound(p);
      expectBooksSound(b);
    });
  });

  group("section 6: the owner spends the business's money directly", () {
    LedgerEntry lunch() => tx(
      1,
      3,
      eat(2026, 11, 21, 13, 5),
      kes(800),
      category: 1,
      type: CategoryType.expense,
      linked: stall,
      kind: TransactionKind.bank,
    );
    LedgerEntry paidYourself({int category = 12}) => tx(
      1,
      2,
      eat(2026, 11, 21, 13, 5),
      kes(800),
      category: category,
      type: stallCategories[category]!.type,
      linked: category == 12 ? personal : null,
      kind: TransactionKind.bank,
    );

    test('step 1: lunch from the KCB, "This was for me"', () {
      p.history.add(lunch());
      b.history.add(paidYourself());
      expect(p.money(1), kes(37819), reason: 'no Personal account goes down');
      expect(p.ownAccounts, kes(37819));
      expect(p.moneyIn, 0, reason: 'spending only, never income');
      expect(p.moneyOut, kes(800));
      expect(p.totals.incomeMinor, 0);
      expect(
        p.balances.balanceOf(const BookAccount.paidBySpace(3), currency: 'KES'),
        kes(800),
      );
      expect(b.money(2), kes(9200));
      expect(b.paidYourself, kes(800));
      expect(b.totals.spendingMinor, 0, reason: 'never a cost');
      expect(b.profit, 0);
      expect(p.ownAccounts + b.money(2), kes(47019));
      expectBooksSound(p);
      expectBooksSound(b);
    });

    test('step 2: stock from the M-Pesa, "Business cost"', () {
      p.history.add(lunch());
      b.history.add(paidYourself());
      cost(2, eat(2026, 11, 21, 15), kes(400), kes(37419));
      expect(p.money(1), kes(37419));
      expect(p.moneyIn, 0);
      expect(p.moneyOut, kes(800));
      expect(p.between.heldFor(stall), -kes(400), reason: 'stall owes 400');
      expect(b.between.putInMinor, kes(400));
      expect(b.money(2), kes(9200));
      expect(b.profit, -kes(400));
      expect(p.ownAccounts + b.money(2), kes(46619));
      expectBooksSound(p);
      expectBooksSound(b);
    });

    test('step 3: the lunch was for the helper after all', () {
      p.history.add(lunch());
      b.history.add(paidYourself());
      cost(2, eat(2026, 11, 21, 15), kes(400), kes(37419));
      // "This was for the business": Personal's entry goes, Paid yourself
      // becomes a cost.
      p.history.removeWhere((e) => e.id == 1);
      b.history
        ..removeWhere((e) => e.id == 1)
        ..add(paidYourself(category: 13));
      expect(p.moneyOut, 0);
      expect(p.money(1), kes(37419));
      expect(b.paidYourself, 0);
      expect(b.profit, -kes(1200));
      expect(b.money(2), kes(9200));
      expect(b.between.putInMinor, kes(400));
      expectBooksSound(p);
      expectBooksSound(b);
    });
  });

  test('random histories: the two sides always agree', () {
    final random = Random(27);
    for (var run = 0; run < 40; run++) {
      final ps = Space(personalAccounts, personalCategories);
      final bs = Space(stallAccounts, stallCategories);
      var wallet = kes(37819);
      var at = eat(2026, 11, 1, 8);
      for (var i = 1; i <= 30; i++) {
        at = at.add(Duration(minutes: 30 + random.nextInt(600)));
        final amount = kes(50 + random.nextInt(2000));
        switch (random.nextInt(4)) {
          case 0:
            wallet += amount;
            ps.history.add(
              record(i, at, amount, inflow: true, balance: wallet),
            );
            bs.history.add(
              tx(
                i,
                3,
                at,
                amount,
                inflow: true,
                category: 10,
                linked: personal,
              ),
            );
          case 1:
            wallet -= amount;
            ps.history.add(record(i, at, amount, balance: wallet));
            bs.history.add(
              tx(i, 3, at, amount, category: 11, linked: personal),
            );
          case 2:
            ps.history.add(
              tx(i, 2, at, amount, inflow: true, category: 2, linked: stall),
            );
            bs.history.add(
              tx(i, 3, at, amount, category: 12, linked: personal),
            );
          default:
            wallet -= amount;
            ps.history.add(tx(i, 1, at, amount, category: 3, balance: wallet));
        }
        expect(
          ps.between.heldFor(stall),
          bs.between.onAccountsOf(personal),
          reason:
              'run $run step $i: Held for the stall is the owner\'s account',
        );
        expect(ps.money(1), wallet, reason: 'the wallet, as reported');
      }
      expectBooksSound(ps);
      expectBooksSound(bs);
    }
  });

  test("the business's balance summary shows its money with the owner, "
      'and what the owner has put in, apart from cash, M-Pesa and bank', () {
    sale(1, eat(2026, 11, 20, 17, 6), kes(650), kes(38469));
    final period = ReportPeriod(
      CalendarDate(2026, 11, 1),
      CalendarDate(2026, 12, 1),
      'November',
    );
    var books = Books.of(
      b.history,
      accounts: stallAccounts,
      categories: stallCategories,
    );
    var summary = balanceSummary(books, period, currency: 'KES');
    expect(summary.moneyMinor, kes(12000), reason: 'cash 2,000 and KCB');
    expect(summary.withOwnerMinor, kes(650), reason: 'With the owner');
    cost(2, eat(2026, 11, 20, 18, 20), kes(1000), kes(37469));
    books = Books.of(
      b.history,
      accounts: stallAccounts,
      categories: stallCategories,
    );
    summary = balanceSummary(books, period, currency: 'KES');
    expect(summary.withOwnerMinor, -kes(350), reason: 'Owed to the owner');
    expect(summary.moneyMinor, kes(12000));
  });
}
