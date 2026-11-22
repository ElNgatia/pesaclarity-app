import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/books/book_account.dart';
import 'package:pesaclarity/src/domain/books/journal.dart';
import 'package:pesaclarity/src/domain/books/journal_balances.dart';
import 'package:pesaclarity/src/domain/budget/safe_to_spend.dart';
import 'package:pesaclarity/src/domain/categoriser/suggester.dart';
import 'package:pesaclarity/src/domain/enums.dart';
import 'package:pesaclarity/src/domain/ledger/balances.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_entry.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_role.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_totals.dart';
import 'package:pesaclarity/src/domain/lending/loan_link.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';

import '../fixtures.dart';

void main() {
  const moneyLent = 7;
  final categories = {moneyLent: (key: 'money_lent', type: CategoryType.debt)};

  LedgerEntry linked({
    required int id,
    required int shillings,
    required TransactionDirection direction,
    int day = 3,
  }) => LedgerEntry(
    id: id,
    accountId: 1,
    occurredAt: eat(2026, 11, day),
    amountMinor: kes(shillings),
    direction: direction,
    kind: direction == TransactionDirection.outflow
        ? TransactionKind.sent
        : TransactionKind.received,
    payeeId: 3,
    categoryId: moneyLent,
    categoryType: CategoryType.debt,
    // A day-to-day category would still not make it spending.
    isDailySpending: true,
    lentLoanId: 1,
  );

  final opening = AccountOpening(
    id: 1,
    type: AccountType.mpesa,
    openingBalanceMinor: kes(20000),
    openingDate: eat(2026, 11, 1, 0),
  );

  test('money lent and paid back is lending: never spending or income', () {
    final lent = linked(
      id: 1,
      shillings: 5000,
      direction: TransactionDirection.outflow,
    );
    final back = linked(
      id: 2,
      shillings: 2000,
      direction: TransactionDirection.inflow,
      day: 10,
    );
    for (final e in [lent, back]) {
      expect(roleOf(e), LedgerRole.lending);
      expect(neutralRoles, contains(roleOf(e)));
      expect(isMoneyArrived(e), isFalse);
      expect(dayToDaySpendOf(e), 0);
      expect(needsCategory(e), isFalse);
    }
    final totals = LedgerTotals.of(
      [lent, back],
      from: eat(2026, 11, 1, 0),
      to: eat(2026, 12, 1, 0),
    );
    expect(totals.spendingMinor, 0);
    expect(totals.incomeMinor, 0);
    expect(totals.moneyInMinor, 0);
    expect(totals.debtRepaymentMinor, 0);
    expect(totals.borrowingMinor, 0);
  });

  test('the journal posts it against Owed to you', () {
    final entries = postJournal(
      accounts: [opening],
      history: [
        linked(id: 1, shillings: 5000, direction: TransactionDirection.outflow),
        linked(
          id: 2,
          shillings: 2000,
          direction: TransactionDirection.inflow,
          day: 10,
        ),
      ],
      categories: categories,
    );
    expect(entries.every((e) => e.isBalanced), isTrue);
    final books = JournalBalances(entries);
    expect(books.balanceOf(BookAccount.owedToYou, currency: 'KES'), kes(3000));
    expect(
      books.balanceOf(const BookAccount.money(1), currency: 'KES'),
      kes(17000),
    );
    expect(
      books.balanceOf(
        const BookAccount.category(moneyLent, income: false),
        currency: 'KES',
      ),
      0,
    );
  });

  test('without its link, money lent falls back to its category', () {
    final e = entry(
      at: eat(2026, 11, 3),
      amount: kes(100),
      categoryId: moneyLent,
      categoryType: CategoryType.debt,
    );
    expect(roleOf(e), LedgerRole.debtRepayment);
  });

  test('what each direction offers, and how Activity names it', () {
    expect(LoanLink.forDirection(outflow: true), [
      LoanLink.lent,
      LoanLink.repaidBorrowed,
    ]);
    expect(LoanLink.forDirection(outflow: false), [
      LoanLink.borrowed,
      LoanLink.repaidLent,
    ]);
    expect(loanLinkLabel(LoanLink.lent, 'Test Grace'), 'Lent to Test Grace');
    expect(
      loanLinkLabel(LoanLink.borrowed, 'Test Grace'),
      'Borrowed from Test Grace',
    );
  });

  test('only Personal-style spaces track lending', () {
    expect(
      [
        for (final kind in SpaceKind.values)
          if (kind.tracksLending) kind,
      ],
      [SpaceKind.personal, SpaceKind.household, SpaceKind.other],
    );
  });
}
