import 'package:drift/drift.dart';

import '../../domain/ledger/message_twins.dart';
import '../database/app_database.dart';
import 'app_settings_repository.dart';
import 'journal_repository.dart';
import 'message_twins_store.dart';
import 'savings_links.dart';
import 'transactions_repository.dart';

/// What one [repairBalances] run changed.
typedef BalancesRepair = ({int walletCredits, int copies});

/// Where a space's settings keep the version of [repairBalances] it ran.
const balancesRepairKey = 'ledger.balancesRepaired';

/// The version of [repairBalances]: raised when it learns something new to
/// put right.
const balancesRepairVersion = 1;

/// Puts right, once per [balancesRepairVersion], the money counted twice by
/// earlier versions, keeping every message:
///
/// * a bank's notice on M-Pesa and M-Pesa's own message for the same money
///   in ([TwinMatch.walletCredit]) kept as two transactions, which doubled
///   the wallet: merged as new messages now merge ([mergeStoredWalletCredits]);
/// * rows made twice from one message ([removeMessageCopies]).
///
/// Then pairs own transfers again and reposts the whole journal from the
/// records, which reverses any entry the records no longer hold. Returns
/// null when it had already run.
Future<BalancesRepair?> repairBalancesOnce(AppDatabase db) async {
  final settings = DriftAppSettingsRepository(db);
  final done = (await settings.readJson(balancesRepairKey))?['version'];
  if (done is int && done >= balancesRepairVersion) return null;
  final repaired = await repairBalances(db);
  await settings.writeJson(balancesRepairKey, {
    'version': balancesRepairVersion,
  });
  return repaired;
}

/// The work of [repairBalancesOnce], safe to run again.
Future<BalancesRepair> repairBalances(AppDatabase db) async {
  final repaired = await db.transaction(
    () async => (
      copies: await removeMessageCopies(db),
      walletCredits: await mergeStoredWalletCredits(db),
    ),
  );
  if (repaired.copies > 0 || repaired.walletCredits > 0) {
    await syncSavingsAccounts(db);
    await DriftTransactionsRepository(db).pairOwnTransfers();
  }
  await JournalRepository.markForRebuild(db);
  await JournalRepository(db).sync();
  return repaired;
}

/// Merges each bank notice on M-Pesa into M-Pesa's own message for the
/// same money, as [findTwin] pairs them for new messages: the same
/// reference first, then the M-Pesa message naming the same sender, then
/// the nearest in time, one notice to one M-Pesa message. The M-Pesa
/// message stays the record (its receipt, time and balance) and keeps the
/// notice's message as its twin, so reading or clearing either treats them
/// as one. Returns how many notices were merged.
Future<int> mergeStoredWalletCredits(AppDatabase db) async {
  final t = db.transactions;
  final rows =
      await (db.select(t)
            ..where(
              (t) =>
                  t.direction.equalsValue(TransactionDirection.inflow) &
                  t.source.equalsValue(TransactionSource.sms) &
                  t.messageHash.isNotNull(),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.occurredAt),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .get();
  final taken = <int>{};
  var merged = 0;
  for (final notice in rows) {
    if (taken.contains(notice.id)) continue;
    if (!walletNoticeBanks.contains(packOf(notice.readBy))) continue;
    final incoming = twinFactsOf(notice);
    ({TransactionRecord record, TwinMatch match, bool named, Duration gap})?
    best;
    for (final wallet in rows) {
      if (wallet.id == notice.id ||
          wallet.accountId != notice.accountId ||
          taken.contains(wallet.id)) {
        continue;
      }
      final facts = twinFactsOf(wallet);
      final match = twinMatch(facts, incoming);
      if (match == null) continue;
      if (match == TwinMatch.walletCredit &&
          walletCreditSide(facts, incoming) != true) {
        continue;
      }
      final named = walletCreditNamesAgree(facts, incoming);
      final gap = wallet.occurredAt.difference(notice.occurredAt).abs();
      if (best == null ||
          match.index < best.match.index ||
          (match == best.match && named && !best.named) ||
          (match == best.match && named == best.named && gap < best.gap)) {
        best = (record: wallet, match: match, named: named, gap: gap);
      }
    }
    if (best == null) continue;
    final wallet = best.record;
    // A notice that already held a twin of its own: that message stays out
    // when the records are read again.
    if (notice.twinMessageHash case final extra?) {
      await db
          .into(db.setAsideMessages)
          .insertOnConflictUpdate(
            SetAsideMessagesCompanion.insert(messageHash: extra),
          );
    }
    await mergeTwin(db, wallet, notice.toCompanion(true), match: best.match);
    await _removeInto(db, notice, wallet);
    taken
      ..add(notice.id)
      ..add(wallet.id);
    merged++;
  }
  return merged;
}

/// Removes rows made twice from one message: a second row with the same
/// message as another, or one whose message another row already holds as
/// its twin. The oldest row stays. Returns how many were removed.
Future<int> removeMessageCopies(AppDatabase db) async {
  final rows = await (db.select(
    db.transactions,
  )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
  final byHash = <String, TransactionRecord>{};
  for (final r in rows) {
    if (r.messageHash case final h?) byHash.putIfAbsent(h, () => r);
  }
  var removed = 0;
  final gone = <int>{};
  for (final r in rows) {
    final hash = r.messageHash;
    if (hash == null) continue;
    final kept = byHash[hash]!;
    if (kept.id != r.id) {
      await _removeInto(db, r, kept);
      gone.add(r.id);
      removed++;
    }
  }
  for (final r in rows) {
    final twin = r.twinMessageHash;
    if (twin == null || gone.contains(r.id)) continue;
    final copy = byHash[twin];
    if (copy == null || copy.id == r.id || gone.contains(copy.id)) continue;
    if (copy.accountId != r.accountId || copy.amountMinor != r.amountMinor) {
      continue;
    }
    await _removeInto(db, copy, r);
    gone.add(copy.id);
    removed++;
  }
  return removed;
}

/// Removes [copy], the same money as [kept]: what the person set on the
/// copy and does not have on [kept] moves there, and so do its links.
Future<void> _removeInto(
  AppDatabase db,
  TransactionRecord copy,
  TransactionRecord kept,
) async {
  final now = await (db.select(
    db.transactions,
  )..where((t) => t.id.equals(kept.id))).getSingle();
  await (db.update(db.transactions)..where((t) => t.id.equals(kept.id))).write(
    TransactionsCompanion(
      categoryOverrideId: Value(
        now.categoryOverrideId ?? copy.categoryOverrideId,
      ),
      payeeId: Value(now.payeeId ?? copy.payeeId),
      item: Value(now.item ?? copy.item),
      goalId: Value(now.goalId ?? copy.goalId),
      debtId: Value(now.debtId ?? copy.debtId),
      transferAccountId: Value(now.transferAccountId ?? copy.transferAccountId),
    ),
  );
  for (final table in ['sale_payments', 'quick_records']) {
    await db.customStatement(
      'UPDATE $table SET transaction_id = ? WHERE transaction_id = ?',
      [kept.id, copy.id],
    );
  }
  await db.customStatement(
    'INSERT OR IGNORE INTO transaction_tags (transaction_id, tag_id) '
    'SELECT ?, tag_id FROM transaction_tags WHERE transaction_id = ?',
    [kept.id, copy.id],
  );
  await (db.update(db.transactions)
        ..where((t) => t.transferPairId.equals(copy.id)))
      .write(const TransactionsCompanion(transferPairId: Value(null)));
  await (db.delete(db.transactions)..where((t) => t.id.equals(copy.id))).go();
}
