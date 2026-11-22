import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/categories/default_categories.dart';
import '../../domain/lending/loan_link.dart';
import '../../domain/time/calendar.dart';
import '../database/app_database.dart';
import '../database/database_providers.dart';
import 'category_seeds.dart';
import 'debts_repository.dart';
import 'lending_repository.dart';

/// A transaction's link to a loan in Lent and borrowed, with the name the
/// loan goes by.
typedef LoanLinkOf = ({LoanLink link, String person});

/// Transactions that are money lent or borrowed between the person,
/// friends and family, linked to their loan in Lent and borrowed.
///
/// Money out lent ([lend]) makes a lent loan and money in paying it back
/// ([paidBack]) lowers it, both through the transaction's `lentLoanId`;
/// the journal posts them against Owed to you, so neither is spending or
/// income. Money in borrowed ([borrow]) makes a family debt and money out
/// paying it back ([payBack]) lowers it, both through `debtId`; the journal
/// posts them against Borrowed. [unlink] takes each back.
abstract interface class LoanLinksRepository {
  /// Records [transactionId], money out, as money lent to [person]: a new
  /// loan linked to it. Returns the loan's id.
  Future<int> lend(
    int transactionId, {
    required String person,
    required int amountMinor,
    required CalendarDate lentOn,
    CalendarDate? dueDate,
    String? note,
  });

  /// Files [transactionId], money out, as paying back the oldest money
  /// borrowed from its payee that is still owed. Returns false when there
  /// is none: it is then filed as a loan repayment with no loan to lower.
  Future<bool> payBack(int transactionId);

  /// Files [transactionId], money in, as a loan from its payee: a family
  /// debt linked to it.
  Future<void> borrow(int transactionId);

  /// Files [transactionId], money in, as paying back the oldest money lent
  /// to its payee that is still owed. Returns false when there is none: it
  /// is then filed as an own transfer, as "Paying you back" always was.
  Future<bool> paidBack(int transactionId);

  /// Takes back what [lend], [payBack], [borrow] or [paidBack] did: the
  /// link, and the loan or debt it made. The category is left to the
  /// caller.
  Future<void> unlink(int transactionId);

  /// What [transactionId] is linked to; null when nothing.
  Future<LoanLinkOf?> linkOf(int transactionId);

  /// Every linked transaction's link, by transaction id, for Activity.
  Stream<Map<int, LoanLinkOf>> watchLinks();
}

class DriftLoanLinksRepository implements LoanLinksRepository {
  DriftLoanLinksRepository(this._db);

  final AppDatabase _db;

  Future<TransactionRecord> _transaction(int id) =>
      (_db.select(_db.transactions)..where((t) => t.id.equals(id))).getSingle();

  Future<void> _write(int id, TransactionsCompanion changes) => (_db.update(
    _db.transactions,
  )..where((t) => t.id.equals(id))).write(changes);

  @override
  Future<int> lend(
    int transactionId, {
    required String person,
    required int amountMinor,
    required CalendarDate lentOn,
    CalendarDate? dueDate,
    String? note,
  }) => _db.transaction(() async {
    await unlinkLoan(_db, transactionId);
    final tx = await _transaction(transactionId);
    final loan = await DriftLendingRepository(_db).add(
      person: person,
      amountMinor: amountMinor,
      lentOn: lentOn,
      dueDate: dueDate,
      note: note,
      currency: tx.currency,
    );
    await _write(
      transactionId,
      TransactionsCompanion(
        lentLoanId: Value(loan),
        categoryOverrideId: Value(await ensureCategory(_db, moneyLentSeed)),
      ),
    );
    return loan;
  });

  @override
  Future<bool> payBack(int transactionId) => _db.transaction(() async {
    await unlinkLoan(_db, transactionId);
    final tx = await _transaction(transactionId);
    final name = await personOf(_db, tx);
    int? debtId;
    if (name != null) {
      final key = _key(name);
      final debts = await DriftDebtsRepository(_db)
          .debts(today: CalendarDate.local(tx.occurredAt));
      final open = [
        for (final d in debts)
          if (!d.isFormal &&
              d.currency == tx.currency &&
              d.balanceMinor > 0 &&
              ((tx.payeeId != null && d.payeeId == tx.payeeId) ||
                  _key(d.lender) == key))
            d.id,
      ]..sort();
      debtId = open.firstOrNull;
    }
    await _write(
      transactionId,
      TransactionsCompanion(
        debtId: Value(debtId),
        categoryOverrideId: Value(await _categoryId(loanCategoryKey)),
      ),
    );
    return debtId != null;
  });

  @override
  Future<void> borrow(int transactionId) => _db.transaction(() async {
    await unlinkLoan(_db, transactionId);
    final tx = await _transaction(transactionId);
    await borrowInto(_db, tx, lender: await personOf(_db, tx) ?? 'Loan');
  });

  @override
  Future<bool> paidBack(int transactionId) => _db.transaction(() async {
    await unlinkLoan(_db, transactionId);
    final tx = await _transaction(transactionId);
    return payBackLent(_db, tx);
  });

  @override
  Future<void> unlink(int transactionId) => unlinkLoan(_db, transactionId);

  Future<int?> _categoryId(String key) async => (await (_db.select(
    _db.categories,
  )..where((c) => c.key.equals(key))).getSingleOrNull())?.id;

  @override
  Future<LoanLinkOf?> linkOf(int transactionId) async {
    final links = await _links((t) => t.id.equals(transactionId))
        .getSingleOrNull();
    return links?.$2;
  }

  @override
  Stream<Map<int, LoanLinkOf>> watchLinks() =>
      _links((_) => const Constant(true))
          .watch()
          .map((rows) => {for (final (id, link) in rows) id: link});

  /// The links of the transactions [where] picks, each as its id and link.
  Selectable<(int, LoanLinkOf)> _links(
    Expression<bool> Function($TransactionsTable t) where,
  ) {
    final t = _db.transactions;
    final l = _db.lentLoans;
    final d = _db.debts;
    final query =
        _db.select(t).join([
          leftOuterJoin(l, l.id.equalsExp(t.lentLoanId)),
          leftOuterJoin(d, d.id.equalsExp(t.debtId) & d.isFormal.not()),
        ])..where(
          where(t) &
              (l.id.isNotNull() | (d.id.isNotNull() & t.lentLoanId.isNull())),
        );
    return query.map((row) {
      final tx = row.readTable(t);
      final out = tx.direction == TransactionDirection.outflow;
      final lent = row.readTableOrNull(l);
      if (lent != null) {
        return (
          tx.id,
          (
            link: out ? LoanLink.lent : LoanLink.repaidLent,
            person: lent.person,
          ),
        );
      }
      final debt = row.readTable(d);
      return (
        tx.id,
        (
          link: out ? LoanLink.repaidBorrowed : LoanLink.borrowed,
          person: debt.lender,
        ),
      );
    });
  }
}

String _key(String name) =>
    name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// The name [tx]'s money goes by: its payee's, else the name its message
/// printed. Null when it has neither.
Future<String?> personOf(AppDatabase db, TransactionRecord tx) async {
  final payeeId = tx.payeeId;
  if (payeeId != null) {
    final payee = await (db.select(
      db.payees,
    )..where((p) => p.id.equals(payeeId))).getSingleOrNull();
    if (payee != null) return payee.displayName;
  }
  final printed = tx.counterpartyName?.trim();
  return printed == null || printed.isEmpty ? null : printed;
}

/// Files [tx], money in, as a loan from [lender]: a family debt of its
/// amount, linked to it.
Future<int> borrowInto(
  AppDatabase db,
  TransactionRecord tx, {
  required String lender,
}) async {
  final name = lender.length > 80 ? lender.substring(0, 80) : lender;
  final debt = await db
      .into(db.debts)
      .insert(
        DebtsCompanion.insert(
          lender: name,
          type: DebtType.family,
          currency: Value(tx.currency),
          startingBalanceMinor: tx.amountMinor,
          isFormal: const Value(false),
          payeeId: Value(tx.payeeId),
        ),
      );
  final category = await (db.select(
    db.categories,
  )..where((c) => c.key.equals(loanCategoryKey))).getSingleOrNull();
  await (db.update(db.transactions)..where((t) => t.id.equals(tx.id))).write(
    TransactionsCompanion(
      debtId: Value(debt),
      categoryOverrideId: Value(category?.id),
    ),
  );
  return debt;
}

/// Files [tx], money in, as paying back the oldest money lent to someone
/// of its payee's name that is still owed, in its currency. Without one it
/// is filed as an own transfer. Returns whether a loan was found.
Future<bool> payBackLent(AppDatabase db, TransactionRecord tx) async {
  final name = await personOf(db, tx);
  final paidOn = CalendarDate.local(tx.occurredAt);
  int? loanId;
  if (name != null) {
    final loans = await DriftLendingRepository(db).lent();
    // Oldest first, so the earliest money lent is paid off first.
    for (final loan in loans.reversed) {
      if (_key(loan.person) != _key(name) || loan.currency != tx.currency) {
        continue;
      }
      if (loan.outstandingAt(paidOn) <= 0) continue;
      loanId = loan.id;
      break;
    }
  }
  final category = loanId == null
      ? await (db.select(db.categories)
              ..where((c) => c.key.equals('own_transfer')))
            .getSingleOrNull()
            .then((c) => c?.id)
      : await ensureCategory(db, moneyLentSeed);
  await (db.update(db.transactions)..where((t) => t.id.equals(tx.id))).write(
    TransactionsCompanion(
      lentLoanId: Value(loanId),
      categoryOverrideId: Value(category),
    ),
  );
  return loanId != null;
}

/// Takes back [transactionId]'s link to a loan, and the loan it made: a
/// loan lent from it is removed, with what paid it back left unlinked and
/// uncategorised; a family debt borrowed in it is removed; a payment on
/// either is unlinked. A formal debt's repayment, which its message links,
/// is left as it is.
Future<void> unlinkLoan(AppDatabase db, int transactionId) => db.transaction(
  () async {
    final tx = await (db.select(
      db.transactions,
    )..where((t) => t.id.equals(transactionId))).getSingleOrNull();
    if (tx == null) return;
    final out = tx.direction == TransactionDirection.outflow;
    final write = db.update(db.transactions)
      ..where((t) => t.id.equals(transactionId));
    if (tx.lentLoanId case final loan?) {
      if (out) {
        await DriftLendingRepository(db).remove(loan);
      } else {
        await write.write(const TransactionsCompanion(lentLoanId: Value(null)));
      }
    }
    final debtId = tx.debtId;
    if (debtId == null) return;
    final debt = await (db.select(
      db.debts,
    )..where((d) => d.id.equals(debtId))).getSingleOrNull();
    if (debt == null || debt.isFormal) return;
    if (out) {
      await write.write(const TransactionsCompanion(debtId: Value(null)));
    } else {
      await DriftDebtsRepository(db).remove(debtId);
    }
  },
);

/// Whether choosing [categoryId] for [tx] takes it out of its loan: a
/// transaction linked to a loan stays linked while it keeps the loan's
/// category.
Future<bool> leavesLoan(
  AppDatabase db,
  TransactionRecord tx,
  int? categoryId,
) async {
  if (tx.lentLoanId == null && tx.debtId == null) return false;
  final category = categoryId == null
      ? null
      : await (db.select(
          db.categories,
        )..where((c) => c.id.equals(categoryId))).getSingleOrNull();
  if (tx.lentLoanId != null) return category?.key != moneyLentSeed.key;
  return category?.key != loanCategoryKey;
}

final loanLinksRepositoryProvider = Provider<LoanLinksRepository>(
  (ref) => DriftLoanLinksRepository(ref.watch(appDatabaseProvider)),
);
