// The rest of decision 0027 (money between spaces), posted through each
// space's own journal: Put money in, Pay yourself by bank with "Where it
// lands", the restore check and the question on Clear data. Every figure
// is checked in both spaces: balances, In and Out, profit, safe to spend,
// nothing in Not yet sorted and every entry balanced. Made-up numbers only.
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/books/book_account.dart';
import 'package:pesaclarity/src/domain/books/books.dart';
import 'package:pesaclarity/src/domain/books/business_report.dart';
import 'package:pesaclarity/src/domain/enums.dart';
import 'package:pesaclarity/src/domain/ledger/balances.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_entry.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';

import '../fixtures.dart';
import 'money_between_spaces_test.dart' hide main;

// Personal adds Equity bank (4) and Cash (5); the stall's Cash is 1 and
// KCB 2. Categories: Put into my business 4 in Personal, Put money in 14
// in the stall.
final personalPlus = [
  ...personalAccounts,
  AccountOpening(
    id: 4,
    type: AccountType.bank,
    openingBalanceMinor: kes(20000),
    openingDate: start,
  ),
  AccountOpening(
    id: 5,
    type: AccountType.cash,
    openingBalanceMinor: kes(1500),
    openingDate: start,
  ),
];
const personalCategoriesPlus = <int, BookCategory>{
  ...personalCategories,
  4: (key: 'put_into_business', type: CategoryType.transfer),
};
const stallCategoriesPlus = <int, BookCategory>{
  ...stallCategories,
  14: (key: 'owner_capital', type: CategoryType.transfer),
};

/// The stall's Cash and KCB, and its owner's account starting at [onLine]:
/// what Clear data's "Keep it apart" leaves.
List<AccountOpening> stallWith({int onLine = 0}) => [
  for (final a in stallAccounts)
    a.id == 3
        ? AccountOpening(
            id: 3,
            type: AccountType.ownersAccount,
            openingBalanceMinor: onLine,
            openingDate: start,
          )
        : a,
];

void main() {
  late Space p;
  late Space b;
  setUp(() {
    p = Space(personalPlus, personalCategoriesPlus);
    b = Space(stallAccounts, stallCategoriesPlus);
  });

  /// Safe to spend is worked from Personal's own accounts less what they
  /// hold for other spaces.
  int spendable(Space s) => s.ownAccounts - s.between.notOwnMinor;

  /// The money already between the spaces in decision 0027's worked
  /// example: a 650 sale and a 400 supplier on the owner's M-Pesa, and Pay
  /// yourself 200 on it, so KES 50 of the M-Pesa is the stall's.
  void stepsOneToThree() {
    p.history.add(
      record(
        1,
        eat(2026, 11, 20, 17, 6),
        kes(650),
        inflow: true,
        balance: kes(38469),
      ),
    );
    b.history.add(
      tx(
        1,
        3,
        eat(2026, 11, 20, 17, 6),
        kes(650),
        inflow: true,
        category: 10,
        type: CategoryType.income,
        linked: personal,
      ),
    );
    p.history.add(
      record(2, eat(2026, 11, 20, 18, 20), kes(400), balance: kes(38069)),
    );
    b.history.add(
      tx(
        2,
        3,
        eat(2026, 11, 20, 18, 20),
        kes(400),
        category: 11,
        type: CategoryType.expense,
        linked: personal,
      ),
    );
    p.history.add(
      tx(
        3,
        2,
        eat(2026, 11, 21, 9),
        kes(200),
        inflow: true,
        category: 2,
        type: CategoryType.income,
        linked: stall,
      ),
    );
    b.history.add(
      tx(
        3,
        3,
        eat(2026, 11, 21, 9),
        kes(200),
        category: 12,
        type: CategoryType.transfer,
        linked: personal,
      ),
    );
  }

  void expectSound() {
    expectBooksSound(p);
    expectBooksSound(b);
  }

  int putInByYou(Space s) =>
      s.balances.balanceOf(BookAccount.ownerCapital, currency: 'KES');

  group('Put money in', () {
    setUp(stepsOneToThree);

    test('from your M-Pesa, staying on it: no money moves, KES 3,000 of the '
        "M-Pesa becomes the stall's, never a sale or spending", () {
      final outBefore = p.moneyOut;
      final spendableBefore = spendable(p);
      p.history.add(
        tx(
          10,
          2,
          eat(2026, 11, 21, 10, 12),
          kes(3000),
          category: 4,
          type: CategoryType.transfer,
          linked: stall,
        ),
      );
      b.history.add(
        tx(
          10,
          3,
          eat(2026, 11, 21, 10, 12),
          kes(3000),
          inflow: true,
          category: 14,
          type: CategoryType.transfer,
          linked: personal,
        ),
      );
      // Personal: M-Pesa and On hand stay 38,069; 3,050 of it is the
      // stall's; nothing is spent, so Out this week and the Plan stay.
      expect(p.money(1), kes(38069));
      expect(p.between.heldFor(stall), kes(3050));
      expect(p.moneyOut, outBefore);
      expect(p.totals.spendingMinor, 0);
      expect(p.totals.incomeMinor, kes(200), reason: 'only the pay');
      expect(spendable(p), spendableBefore - kes(3000));
      // The stall: On your M-Pesa 50 to 3,050; In 3,000 on its line; profit
      // stays 250: it is not a sale.
      expect(b.between.onAccountsOf(personal), kes(3050));
      expect(b.profit, kes(250));
      expect(b.totals.incomeMinor, kes(650));
      expect(putInByYou(b), kes(3000), reason: '"Put in by you"');
      expect(b.between.putInMinor, 0, reason: "0027's own wording unchanged");
      expect(
        p.money(1) -
            p.between.heldFor(stall) +
            b.between.onAccountsOf(personal),
        kes(38069),
        reason: 'the wallet, counted once',
      );
      expectSound();
    });

    test('from Equity bank into the KCB: each side its own message', () {
      p.history.add(
        tx(
          10,
          4,
          eat(2026, 11, 21, 10, 12),
          kes(3000),
          category: 4,
          type: CategoryType.transfer,
          kind: TransactionKind.bank,
        ),
      );
      b.history.add(
        tx(
          10,
          2,
          eat(2026, 11, 21, 10, 20),
          kes(3000),
          inflow: true,
          category: 14,
          type: CategoryType.transfer,
          kind: TransactionKind.bank,
        ),
      );
      expect(p.money(4), kes(17000));
      expect(p.between.heldFor(stall), kes(50), reason: 'the line unchanged');
      expect(p.totals.spendingMinor, 0);
      expect(p.moneyIn, kes(200));
      expect(b.money(2), kes(13000));
      expect(b.profit, kes(250));
      expect(b.totals.incomeMinor, kes(650));
      expect(putInByYou(b), kes(3000));
      final summary = balanceSummary(
        Books.of(
          b.transactions,
          accounts: b.accounts,
          categories: b.categories,
        ),
        ReportPeriod(
          CalendarDate(2026, 11, 1),
          CalendarDate(2026, 12, 1),
          'November',
        ),
        currency: 'KES',
      );
      expect(summary.putInMinor, kes(3000));
      expectSound();
    });

    test('from your cash into Business cash: both sides at once', () {
      p.history.add(
        tx(
          10,
          5,
          eat(2026, 11, 21, 10, 12),
          kes(1000),
          category: 4,
          type: CategoryType.transfer,
          kind: TransactionKind.withdrawal,
        ),
      );
      b.history.add(
        tx(
          10,
          1,
          eat(2026, 11, 21, 10, 12),
          kes(1000),
          inflow: true,
          category: 14,
          type: CategoryType.transfer,
          kind: TransactionKind.deposit,
        ),
      );
      expect(p.money(5), kes(500));
      expect(b.money(1), kes(3000));
      expect(p.totals.spendingMinor, 0);
      expect(b.profit, kes(250));
      expectSound();
    });
  });

  group('Pay yourself by bank: where it lands', () {
    setUp(stepsOneToThree);

    void paidFromKcb() => b.history.add(
      tx(
        20,
        2,
        eat(2026, 11, 21, 11, 40),
        kes(2500),
        category: 12,
        type: CategoryType.transfer,
        kind: TransactionKind.bank,
      ),
    );

    test('Your M-Pesa: the M-Pesa message is the pay, counted once', () {
      paidFromKcb();
      // The message, matched to the pay and filed as Salary from my
      // business: the only row, so In this week is 2,500 more, not 5,000.
      p.history.add(
        tx(
          20,
          1,
          eat(2026, 11, 21, 11, 41),
          kes(2500),
          inflow: true,
          category: 2,
          type: CategoryType.income,
          balance: kes(40569),
          kind: TransactionKind.received,
        ),
      );
      expect(p.money(1), kes(40569));
      expect(p.totals.incomeMinor, kes(2700));
      expect(p.between.heldFor(stall), kes(50));
      expect(b.money(2), kes(7500));
      expect(b.paidYourself, kes(2700));
      expect(b.profit, kes(250), reason: 'never a cost');
      expectSound();
    });

    test('Not tracked here: Personal counts the pay; none of its accounts '
        'goes up', () {
      final onHand = p.ownAccounts;
      paidFromKcb();
      p.history.add(
        tx(
          20,
          3,
          eat(2026, 11, 21, 11, 40),
          kes(2500),
          inflow: true,
          category: 2,
          type: CategoryType.income,
          kind: TransactionKind.bank,
        ),
      );
      expect(p.ownAccounts, onHand, reason: 'On hand does not change');
      expect(p.totals.incomeMinor, kes(2700));
      expect(p.money(1), kes(38069));
      expect(b.money(2), kes(7500));
      expect(b.profit, kes(250));
      expectSound();
    });
  });

  group('restore check', () {
    // The stall restored from before the sale, the supplier and a second
    // sale: Personal still holds 650 - 400 + 1,200 = 1,450 as the stall's.
    void personalHoldsThree() {
      p.history
        ..add(
          LedgerEntry(
            id: -1,
            accountId: 1,
            occurredAt: eat(2026, 11, 18, 17, 6),
            amountMinor: kes(650),
            direction: TransactionDirection.inflow,
            kind: TransactionKind.received,
            balanceAfterMinor: kes(38469),
            linkedSpaceId: stall,
            heldForAccountId: 2,
          ),
        )
        ..add(
          record(2, eat(2026, 11, 19, 18, 20), kes(400), balance: kes(38069)),
        )
        ..add(
          LedgerEntry(
            id: -3,
            accountId: 1,
            occurredAt: eat(2026, 11, 20, 9, 15),
            amountMinor: kes(1200),
            direction: TransactionDirection.inflow,
            kind: TransactionKind.received,
            balanceAfterMinor: kes(39269),
            linkedSpaceId: stall,
            heldForAccountId: 2,
          ),
        );
    }

    test('before: the stall is short, Personal holds 1,450 for it', () {
      personalHoldsThree();
      expect(p.between.heldFor(stall), kes(1450));
      expect(b.between.onAccountsOf(personal), 0);
      expectSound();
    });

    test('"Make them again": money in as Sales, money out not yet sorted; '
        'both sides agree again', () {
      personalHoldsThree();
      for (final (id, at, amount, inflow) in [
        (1, eat(2026, 11, 18, 17, 6), kes(650), true),
        (2, eat(2026, 11, 19, 18, 20), kes(400), false),
        (3, eat(2026, 11, 20, 9, 15), kes(1200), true),
      ]) {
        b.history.add(
          tx(
            id,
            3,
            at,
            amount,
            inflow: inflow,
            category: inflow ? 10 : null,
            type: inflow ? CategoryType.income : null,
            linked: personal,
            kind: inflow ? TransactionKind.received : TransactionKind.sent,
          ),
        );
      }
      expect(b.between.onAccountsOf(personal), kes(1450));
      expect(p.between.heldFor(stall), kes(1450));
      expect(b.totals.incomeMinor, kes(1850));
      expect(b.totals.spendingMinor, kes(400));
      expect(b.profit, kes(1450));
      expect(p.money(1), kes(39269));
      expect(p.moneyIn, 0, reason: 'no row in Personal');
      expect(spendable(p), p.ownAccounts - kes(1450));
      expectSound();
    });

    test('"They were mine": Personal\'s own payments again, the stall\'s '
        'part undone', () {
      // The balance records become Personal's own payments on the M-Pesa.
      p.history
        ..add(
          tx(
            31,
            1,
            eat(2026, 11, 18, 17, 6),
            kes(650),
            inflow: true,
            category: 2,
            type: CategoryType.income,
            balance: kes(38469),
            kind: TransactionKind.received,
          ),
        )
        ..add(
          tx(
            32,
            1,
            eat(2026, 11, 19, 18, 20),
            kes(400),
            category: 1,
            type: CategoryType.expense,
            balance: kes(38069),
            kind: TransactionKind.paybill,
          ),
        )
        ..add(
          tx(
            33,
            1,
            eat(2026, 11, 20, 9, 15),
            kes(1200),
            inflow: true,
            category: 2,
            type: CategoryType.income,
            balance: kes(39269),
            kind: TransactionKind.received,
          ),
        );
      expect(p.between.heldFor(stall), 0);
      expect(p.money(1), kes(39269));
      expect(p.totals.incomeMinor, kes(1850));
      expect(p.totals.spendingMinor, kes(400));
      expect(spendable(p), p.ownAccounts);
      expect(b.between.onAccountsOf(personal), 0);
      expect(b.profit, 0);
      expectSound();
    });

    test('Personal restored: its records made again in full, no row added', () {
      // The stall still has its two sales on the owner's M-Pesa.
      b.history
        ..add(
          tx(
            1,
            3,
            eat(2026, 11, 18, 17, 6),
            kes(650),
            inflow: true,
            category: 10,
            type: CategoryType.income,
            linked: personal,
          ),
        )
        ..add(
          tx(
            3,
            3,
            eat(2026, 11, 20, 9, 15),
            kes(1200),
            inflow: true,
            category: 10,
            type: CategoryType.income,
            linked: personal,
          ),
        );
      p.history
        ..add(record(1, eat(2026, 11, 18, 17, 6), kes(650), inflow: true))
        ..add(
          record(
            3,
            eat(2026, 11, 20, 9, 15),
            kes(1200),
            inflow: true,
            balance: kes(39669),
          ),
        );
      expect(p.between.heldFor(stall), kes(1850));
      expect(b.between.onAccountsOf(personal), kes(1850));
      expect(p.money(1), kes(39669));
      expect(p.transactions, isEmpty);
      expect(p.moneyIn, 0);
      expect(b.profit, kes(1850));
      expectSound();
    });
  });

  group('Clear data on the stall, KES 650 of the M-Pesa its', () {
    setUp(() {
      p.history.add(
        LedgerEntry(
          id: -1,
          accountId: 1,
          occurredAt: eat(2026, 11, 18, 17, 6),
          amountMinor: kes(650),
          direction: TransactionDirection.inflow,
          kind: TransactionKind.received,
          balanceAfterMinor: kes(38469),
          linkedSpaceId: stall,
          heldForAccountId: 2,
        ),
      );
    });

    test('"Keep it apart": the cleared stall keeps On your M-Pesa 650 as an '
        'opening amount, so both sides agree', () {
      b = Space(stallWith(onLine: kes(650)), stallCategoriesPlus);
      expect(b.between.onAccountsOf(personal), kes(650));
      expect(p.between.heldFor(stall), kes(650));
      expect(b.profit, 0, reason: 'an opening amount is no sale');
      expect(b.totals.incomeMinor, 0);
      expect(spendable(p), p.ownAccounts - kes(650));
      expectSound();
    });

    test('"It is mine now": filed as pay, nothing held for the stall', () {
      p.history.add(
        tx(
          40,
          2,
          eat(2026, 11, 21),
          kes(650),
          inflow: true,
          category: 2,
          type: CategoryType.income,
          linked: stall,
        ),
      );
      expect(p.between.heldFor(stall), 0);
      expect(p.totals.incomeMinor, kes(650), reason: 'Salary from my business');
      expect(p.money(1), kes(38469), reason: 'no money moves');
      expect(spendable(p), p.ownAccounts);
      expect(b.between.onAccountsOf(personal), 0);
      expectSound();
    });
  });
}
