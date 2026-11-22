import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/income/money_purpose.dart';
import '../../domain/payees/payee_directory.dart';
import '../database/app_database.dart';
import '../database/database_providers.dart';
import 'loan_links_repository.dart';

/// "What was this?" for money in from people whose money has meant
/// different things.
abstract interface class PurposeRepository {
  /// Notes that the person filed money in [transactionId] under
  /// [categoryId]. When that differs from what the payee's money was before,
  /// later money from them asks what it was for.
  Future<void> noteChoice(int transactionId, int categoryId);

  /// Files [transactionId] under [purpose]. With [alwaysUse], the payee
  /// takes that category and stops asking.
  ///
  /// A loan to you adds it to Debts as a family loan from the payee,
  /// linked to the transaction. Paying you back links it to the oldest
  /// money lent to someone of the payee's name that is still owed, which
  /// it lowers (see `LoanLinksRepository`).
  Future<void> answer(
    int transactionId,
    MoneyPurpose purpose, {
    bool alwaysUse = false,
  });

  /// Whether money in from [payeeId] asks what it was for.
  Future<void> setAskPurpose(int payeeId, {required bool ask});
}

class DriftPurposeRepository implements PurposeRepository {
  DriftPurposeRepository(this._db);

  final AppDatabase _db;

  Future<TransactionRecord> _transaction(int id) =>
      (_db.select(_db.transactions)..where((t) => t.id.equals(id))).getSingle();

  Future<Payee?> _payee(int? id) => id == null
      ? Future.value()
      : (_db.select(
          _db.payees,
        )..where((p) => p.id.equals(id))).getSingleOrNull();

  @override
  Future<void> noteChoice(int transactionId, int categoryId) =>
      _db.transaction(() async {
        final tx = await _transaction(transactionId);
        final payee = await _payee(tx.payeeId);
        if (payee == null ||
            payee.askPurpose ||
            tx.direction != TransactionDirection.inflow) {
          return;
        }
        final t = _db.transactions;
        final earlier =
            await (_db.selectOnly(t, distinct: true)
                  ..addColumns([t.categoryOverrideId])
                  ..where(
                    t.payeeId.equals(payee.id) &
                        t.id.equals(transactionId).not() &
                        t.direction.equalsValue(TransactionDirection.inflow) &
                        t.categoryOverrideId.isNotNull(),
                  ))
                .map((row) => row.read(t.categoryOverrideId)!)
                .get();
        if (isMixedSender(
          chosenId: categoryId,
          payeeCategoryId: payee.defaultCategoryId,
          earlierIds: earlier,
        )) {
          await setAskPurpose(payee.id, ask: true);
        }
      });

  @override
  Future<void> answer(
    int transactionId,
    MoneyPurpose purpose, {
    bool alwaysUse = false,
  }) => _db.transaction(() async {
    await unlinkLoan(_db, transactionId);
    final tx = await _transaction(transactionId);
    final payee = await _payee(tx.payeeId);
    final category = await (_db.select(
      _db.categories,
    )..where((c) => c.key.equals(purpose.categoryKey))).getSingleOrNull();
    await (_db.update(_db.transactions)
          ..where((t) => t.id.equals(transactionId)))
        .write(TransactionsCompanion(categoryOverrideId: Value(category?.id)));
    if (payee == null) return;
    if (alwaysUse) {
      await (_db.update(_db.payees)..where((p) => p.id.equals(payee.id))).write(
        PayeesCompanion(
          defaultCategoryId: Value(category?.id),
          askPurpose: const Value(false),
        ),
      );
    }
    switch (purpose) {
      case MoneyPurpose.loanToYou:
        await borrowInto(_db, tx, lender: payee.displayName);
      case MoneyPurpose.payingBack:
        await payBackLent(_db, tx);
      case MoneyPurpose.familySupport ||
          MoneyPurpose.work ||
          MoneyPurpose.gift ||
          MoneyPurpose.sale:
        break;
    }
  });

  @override
  Future<void> setAskPurpose(int payeeId, {required bool ask}) =>
      (_db.update(_db.payees)..where((p) => p.id.equals(payeeId))).write(
        PayeesCompanion(askPurpose: Value(ask)),
      );
}

final purposeRepositoryProvider = Provider<PurposeRepository>(
  (ref) => DriftPurposeRepository(ref.watch(appDatabaseProvider)),
);
