import 'package:drift/drift.dart';

import '../../domain/accounts/mpesa_lines.dart';
import '../database/app_database.dart';
import 'journal_repository.dart';
import 'message_links.dart';
import 'message_reads_repository.dart';
import 'savings_links.dart';
import 'transactions_repository.dart';

/// The spaces on this phone, as [removeLeakedCopies] needs them.
typedef SpacesOnPhone = ({
  /// The space whose records are put right.
  String here,

  /// Every space on the list, Personal first.
  List<String> ids,

  /// Opens a space's database, and says whether the caller must close it.
  Future<(AppDatabase, bool)> Function(String spaceId) open,
});

/// What one [removeLeakedCopies] run changed in the space put right.
typedef LeakRepair = ({
  /// Copies removed here: the space that reads their account holds them.
  int removed,

  /// Copies kept here because the person moved them here or made them this
  /// space's own; the reading space's copy went instead.
  int kept,
});

/// Puts right records a space holds of accounts another space reads.
///
/// Before each account was read in one space (and while the capture could
/// still read the last space's accounts right after a switch, or a business
/// read every message of an account it took from Personal), the same
/// message was stored in two spaces: a business showed Personal's M-Pesa
/// payments as its own, and the two together counted every payment twice.
///
/// For each record here on an account another space reads (Personal first,
/// as `readOnce` leaves an account read in both to Personal), and that the
/// reading space holds as well, by message or by receipt:
///
/// * moved here on purpose (the reading space noted the move, or set the
///   message aside), or made this space's own (a sale, a record, a
///   category, a payee, a note, a goal, a debt, tags, an invoice): it stays
///   here, without the wallet balance its message reported, and the reading
///   space's copy goes as a move would take it;
/// * otherwise the copy here goes and its messages are set aside here, so
///   reading messages again never brings it back.
///
/// A record no other space holds stays where it is. Both spaces' journals
/// are posted again from what is left.
Future<LeakRepair> removeLeakedCopies(
  AppDatabase db,
  SpacesOnPhone spaces,
) async {
  // Who reads each account: the first space on the list that has it on.
  final readers = <String, String>{};
  final dbs = <String, (AppDatabase, bool)>{};
  try {
    for (final id in spaces.ids) {
      final opened = id == spaces.here ? (db, false) : await spaces.open(id);
      dbs[id] = opened;
      for (final row
          in await opened.$1.select(opened.$1.selectedInstitutions).get()) {
        readers.putIfAbsent(row.institutionId, () => id);
      }
    }
    if (!readers.values.any((id) => id != spaces.here)) {
      return (removed: 0, kept: 0);
    }

    final t = db.transactions;
    final a = db.accounts;
    final rows = await (db.select(t).join([
      innerJoin(a, a.id.equalsExp(t.accountId)),
    ])..where(a.institutionId.isNotNull())).get();
    final byReader = <String, List<(TransactionRecord, Account)>>{};
    for (final row in rows) {
      final account = row.readTable(a);
      final reader = readerOfAccount(readers, account);
      if (reader == null || reader == spaces.here) continue;
      (byReader[reader] ??= []).add((row.readTable(t), account));
    }

    var removed = 0;
    var kept = 0;
    for (final MapEntry(key: readerId, value: candidates) in byReader.entries) {
      final reader = dbs[readerId]!.$1;
      final changed = await _repairAgainst(
        db,
        reader,
        here: spaces.here,
        candidates: candidates,
      );
      removed += changed.removed;
      kept += changed.kept;
      if (changed.kept > 0) await _repost(reader);
    }
    if (removed + kept > 0) await _repost(db);
    return (removed: removed, kept: kept);
  } finally {
    for (final (other, close) in dbs.values) {
      if (close) await other.close();
    }
  }
}

/// The space that reads [account], from [readers] (each switched-on id
/// with the first space that has it on): an M-Pesa line's account is read
/// where that line is switched on, else where M-Pesa is (decision 0026,
/// section 6); any other account where its institution is.
String? readerOfAccount(Map<String, String> readers, Account account) {
  final institution = account.institutionId;
  if (institution == null) return null;
  final line = lineOfReference(account.reference);
  return (line == null ? null : readers[lineSelectionId(line)]) ??
      readers[institution];
}

/// Puts right the [candidates] in [db] (space [here]) against [reader],
/// the space that reads their accounts.
Future<LeakRepair> _repairAgainst(
  AppDatabase db,
  AppDatabase reader, {
  required String here,
  required List<(TransactionRecord, Account)> candidates,
}) async {
  final hashes = {
    for (final (c, _) in candidates) ...[?c.messageHash, ?c.twinMessageHash],
  };
  final keys = {for (final (c, _) in candidates) ?c.dedupeKey};
  final rt = reader.transactions;
  final ra = reader.accounts;
  // What the reading space holds of the same messages or receipts.
  final readerRows = <(TransactionRecord, Account)>[
    for (final chunk in _chunks(hashes))
      for (final row
          in await (reader.select(rt).join([
                innerJoin(ra, ra.id.equalsExp(rt.accountId)),
              ])..where(
                rt.messageHash.isIn(chunk) | rt.twinMessageHash.isIn(chunk),
              ))
              .get())
        (row.readTable(rt), row.readTable(ra)),
    for (final chunk in _chunks(keys))
      for (final row in await (reader.select(rt).join([
        innerJoin(ra, ra.id.equalsExp(rt.accountId)),
      ])..where(rt.dedupeKey.isIn(chunk))).get())
        (row.readTable(rt), row.readTable(ra)),
  ];
  final byHash = <String, TransactionRecord>{};
  final byKey = <(String?, String, String), TransactionRecord>{};
  for (final (r, account) in readerRows) {
    for (final h in [?r.messageHash, ?r.twinMessageHash]) {
      byHash.putIfAbsent(h, () => r);
    }
    if (r.dedupeKey case final key?) {
      byKey.putIfAbsent((account.institutionId, r.currency, key), () => r);
    }
  }
  // What the reading space moved here, or set aside.
  final movedHere = {
    for (final m in await (reader.select(
      reader.movedTransactions,
    )..where((m) => m.spaceId.equals(here))).get())
      m.dedupeKey,
  };
  final setAside = <String>{
    for (final chunk in _chunks(hashes))
      ...await (reader.select(reader.setAsideMessages)
            ..where((m) => m.messageHash.isIn(chunk)))
          .map((m) => m.messageHash)
          .get(),
  };
  final ownHere = await _personSet(db, [for (final (c, _) in candidates) c]);
  final ownThere = await _personSet(reader, [
    for (final (r, _) in readerRows) r,
  ]);

  var removed = 0;
  var kept = 0;
  final gone = <int>{};
  for (final (copy, account) in candidates) {
    final twin =
        [
          for (final h in [?copy.messageHash, ?copy.twinMessageHash])
            ?byHash[h],
        ].firstOrNull ??
        (copy.dedupeKey == null
            ? null
            : byKey[(account.institutionId, copy.currency, copy.dedupeKey!)]);
    if (twin == null || gone.contains(twin.id)) continue;
    if (await isSavingsLinked(db, copy.id)) continue;
    final moved =
        (copy.dedupeKey != null && movedHere.contains(copy.dedupeKey)) ||
        [?copy.messageHash, ?copy.twinMessageHash].any(setAside.contains);
    final ours = ownHere.contains(copy.id);
    if (moved || ours) {
      // The person's own in both: both stay, nothing they set is lost.
      if (!moved && ownThere.contains(twin.id)) continue;
      if (await isSavingsLinked(reader, twin.id)) continue;
      await _keepHere(db, copy);
      await _moveAway(reader, twin, to: here);
      gone.add(twin.id);
      kept++;
    } else {
      await db.transaction(() async {
        await setAsideMessagesOf(db, [copy.id]);
        await _remove(db, copy);
      });
      removed++;
    }
  }
  return (removed: removed, kept: kept);
}

/// [copy] stays in a space that does not read its account: the balance its
/// message reported is the reading space's, as a move leaves it.
Future<void> _keepHere(AppDatabase db, TransactionRecord copy) =>
    (db.update(db.transactions)..where((t) => t.id.equals(copy.id))).write(
      const TransactionsCompanion(
        balanceAfterMinor: Value(null),
        claimedBalanceMinor: Value(null),
        owedAfterMinor: Value(null),
        owedDueAt: Value(null),
      ),
    );

/// Takes [row] out of [db] as a move to [to] does, so reading its messages
/// again there never brings it back.
Future<void> _moveAway(
  AppDatabase db,
  TransactionRecord row, {
  required String to,
}) => db.transaction(() async {
  if (row.dedupeKey case final key?) {
    await db
        .into(db.movedTransactions)
        .insertOnConflictUpdate(
          MovedTransactionsCompanion.insert(
            accountId: row.accountId,
            dedupeKey: key,
            spaceId: to,
          ),
        );
  }
  await setAsideMessagesOf(db, [row.id]);
  await unlinkLoanRepayment(db, row);
  await _remove(db, row);
});

Future<void> _remove(AppDatabase db, TransactionRecord row) async {
  // An own transfer's other half stays, now on its own.
  await (db.update(db.transactions)
        ..where((t) => t.transferPairId.equals(row.id)))
      .write(const TransactionsCompanion(transferPairId: Value(null)));
  await (db.delete(db.transactions)..where((t) => t.id.equals(row.id))).go();
}

/// Which of [rows] the person made their own: a category, a payee, a note,
/// a goal, a debt or an own account they chose, or tags, a sale, a record,
/// an invoice or a category they confirmed. Pairing own transfers is the
/// app's, so it does not count.
Future<Set<int>> _personSet(
  AppDatabase db,
  List<TransactionRecord> rows,
) async {
  final found = <int>{
    for (final r in rows)
      if (r.categoryOverrideId != null ||
          r.payeeId != null ||
          r.item != null ||
          r.goalId != null ||
          r.debtId != null ||
          r.transferAccountId != null)
        r.id,
  };
  for (final chunk in _chunks({for (final r in rows) r.id})) {
    final marks = List.filled(chunk.length, '?').join(', ');
    for (final table in const [
      'transaction_tags',
      'sale_payments',
      'quick_records',
      'etims_costs',
      'category_confirmations',
    ]) {
      found.addAll(
        await db
            .customSelect(
              'SELECT DISTINCT transaction_id AS id FROM $table '
              'WHERE transaction_id IN ($marks)',
              variables: [for (final id in chunk) Variable.withInt(id)],
            )
            .map((row) => row.read<int>('id'))
            .get(),
      );
    }
  }
  return found;
}

Iterable<List<T>> _chunks<T>(Set<T> all) sync* {
  final list = all.toList();
  for (var i = 0; i < list.length; i += 400) {
    yield list.sublist(i, i + 400 > list.length ? list.length : i + 400);
  }
}

Future<void> _repost(AppDatabase db) async {
  await syncSavingsAccounts(db);
  await DriftTransactionsRepository(db).pairOwnTransfers();
  await JournalRepository.markForRebuild(db);
  await JournalRepository(db).sync();
}
