import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/accounts/mpesa_lines.dart';
import '../../domain/spaces/space.dart';
import '../../domain/spaces/space_categories.dart';
import '../database/app_database.dart';
import '../database/database_providers.dart';
import '../database/space_databases.dart';
import 'category_seeds.dart';
import 'firefly_triggers.dart';
import 'message_links.dart';
import 'message_reads_repository.dart';
import 'savings_links.dart';

/// Switches a transaction from the open space to another (decision 0027,
/// section 2): from then on it shows only in that space, in its Activity,
/// totals, reports, search and exports. A transaction is always in exactly
/// one space, and can be switched as often as the person likes.
abstract interface class SpaceMoveRepository {
  /// Switches [transactionId] to [spaceId].
  ///
  /// * One read from a message or statement, on an account that lives in
  ///   the open space, goes to [spaceId] on the owner's account there ("On
  ///   your M-Pesa"), with its amount, time, name, category, fee and code
  ///   but no balance. The open space keeps a balance record on the account
  ///   (the amount, time, fee, code and the balance its message printed),
  ///   posted against Held for [spaceId], so the account still adds up and
  ///   the message is never read in again.
  /// * One switched in earlier, on the owner's account, goes back: the
  ///   balance record turns back into the transaction where its account
  ///   lives, with the details this space held, and Held for is as it was.
  /// * A payment out of a business's own account switched to Personal is
  ///   "This was for me" ([forMe]).
  /// * A purchase in Personal paid with a business's money switched to that
  ///   business is "This was for the business" ([forTheBusiness]).
  /// * One typed by hand on an account no messages are read into moves
  ///   outright, onto the account of the same name there, and leaves
  ///   nothing behind.
  ///
  /// Its category comes along when [spaceId] has one with the same key, or
  /// is [toCategoryId]; money in switched to a business with neither is
  /// filed as Sales (approved screens, choice 5). A payment into or out of
  /// a savings account the app keeps stays where it is (see
  /// `isSavingsLinked`).
  Future<void> move(int transactionId, String spaceId, {int? toCategoryId});

  /// "This was for me" on [transactionId], a payment out of a business's
  /// own account (decision 0027, section 6): in the business it becomes
  /// Paid yourself, never a cost; Personal gets the purchase, with no
  /// Personal account going down, "Paid from" the business. Personal files
  /// it under [personalCategoryId], or later.
  Future<void> forMe(int transactionId, {int? personalCategoryId});

  /// "This was for the business" on a purchase with the business's money,
  /// from either side: Personal's entry goes and Paid yourself becomes a
  /// cost, under [costCategoryId] or not yet sorted.
  Future<void> forTheBusiness(int transactionId, {int? costCategoryId});

  /// The categories in [spaceId], to choose one for what moves there.
  Future<List<({int id, String name})>> categoriesIn(String spaceId);
}

class DriftSpaceMoveRepository implements SpaceMoveRepository {
  DriftSpaceMoveRepository(
    this._source,
    this._openTarget, {
    this.sourceSpaceId = personalSpaceId,
    Future<String> Function(String spaceId)? nameOf,
  }) : _nameOf =
           nameOf ?? ((id) async => id == personalSpaceId ? 'Personal' : id);

  final AppDatabase _source;

  /// The open space's id.
  final String sourceSpaceId;

  /// Opens [spaceId]'s database and says whether the caller must close it.
  final Future<(AppDatabase, bool)> Function(String spaceId) _openTarget;

  /// A space's name, for naming the accounts money between spaces keeps.
  final Future<String> Function(String spaceId) _nameOf;

  @override
  Future<List<({int id, String name})>> categoriesIn(String spaceId) async {
    final (target, close) = await _openTarget(spaceId);
    try {
      return [
        for (final c in await (target.select(
          target.categories,
        )..orderBy([(c) => OrderingTerm.asc(c.name)])).get())
          (id: c.id, name: c.name),
      ];
    } finally {
      if (close) await target.close();
    }
  }

  /// Moves each of [transactionIds] to [spaceId], as [move] does, opening
  /// that space's database once.
  Future<void> moveMany(Iterable<int> transactionIds, String spaceId) async {
    final (target, close) = await _openTarget(spaceId);
    try {
      final once = DriftSpaceMoveRepository(
        _source,
        (_) async => (target, false),
        sourceSpaceId: sourceSpaceId,
        nameOf: _nameOf,
      );
      for (final id in transactionIds) {
        await once.move(id, spaceId);
      }
    } finally {
      if (close) await target.close();
    }
  }

  Future<T> _with<T>(
    String spaceId,
    Future<T> Function(AppDatabase db) work,
  ) async {
    final (db, close) = await _openTarget(spaceId);
    try {
      return await work(db);
    } finally {
      if (close) await db.close();
    }
  }

  @override
  Future<void> move(
    int transactionId,
    String spaceId, {
    int? toCategoryId,
  }) async {
    if (spaceId == sourceSpaceId) return;
    if (await isSavingsLinked(_source, transactionId)) return;
    final tx = await (_source.select(
      _source.transactions,
    )..where((t) => t.id.equals(transactionId))).getSingleOrNull();
    if (tx == null) return;
    final account = await _accountOf(_source, tx.accountId);

    switch (account.type) {
      case AccountType.ownersAccount:
        final home = account.linkedSpaceId!;
        await _switchBack(tx, account, toCategoryId: toCategoryId);
        if (home != spaceId) {
          // On to a third space, from the space the account lives in.
          await _with(home, (db) async {
            final back =
                await (db.select(db.transactions)
                      ..where((t) => t.linkId.equals(tx.linkId ?? ''))
                      ..limit(1))
                    .getSingleOrNull();
            if (back == null) return;
            await DriftSpaceMoveRepository(
              db,
              _openTarget,
              sourceSpaceId: home,
              nameOf: _nameOf,
            ).move(back.id, spaceId, toCategoryId: toCategoryId);
          });
        }
        return;
      case AccountType.paidBySpace:
        if (account.linkedSpaceId == spaceId) {
          await forTheBusiness(transactionId, costCategoryId: toCategoryId);
        }
        return;
      case AccountType.heldForSpace:
        // A side of Pay yourself, or a correction of the other space's part:
        // it belongs to the pair, not to one space.
        return;
      case _:
        break;
    }

    if (tx.linkId != null && tx.linkedSpaceId == spaceId) {
      // Already "This was for me": Personal has the purchase.
      return;
    }
    if (account.institutionId != null &&
        !await _reads(_source, account) &&
        await _with(spaceId, (db) => _reads(db, account))) {
      // To the space that reads its account: a copy moved here before
      // money between spaces going back, or an M-Pesa line's payments
      // following the line to the space it was given to. It takes its
      // balance with it, and is never "This was for me".
      await _moveHome(tx, account, spaceId, toCategoryId: toCategoryId);
      return;
    }
    if (spaceId == personalSpaceId &&
        sourceSpaceId != personalSpaceId &&
        tx.direction == TransactionDirection.outflow) {
      await forMe(transactionId, personalCategoryId: toCategoryId);
      return;
    }
    if (account.institutionId == null &&
        tx.source == TransactionSource.manual) {
      await _moveOutright(tx, account, spaceId, toCategoryId: toCategoryId);
      return;
    }
    await _switchAway(tx, account, spaceId, toCategoryId: toCategoryId);
  }

  static Future<Account> _accountOf(AppDatabase db, int id) =>
      (db.select(db.accounts)..where((a) => a.id.equals(id))).getSingle();

  /// The link both sides of a switched payment share, the same however
  /// often it is made, so writing it twice changes nothing.
  String _linkOf(TransactionRecord tx) =>
      'switch:$sourceSpaceId:${tx.accountId}:'
      '${tx.dedupeKey ?? tx.messageHash ?? tx.id}';

  /// The category in [target] for what [tx] was filed under here, by key.
  Future<int?> _sameCategory(AppDatabase target, TransactionRecord tx) async {
    final id = tx.categoryOverrideId ?? tx.autoCategoryId;
    if (id == null) return null;
    final category = await (_source.select(
      _source.categories,
    )..where((c) => c.id.equals(id))).getSingleOrNull();
    final key = category?.key;
    if (key == null) return null;
    return (await (target.select(
      target.categories,
    )..where((c) => c.key.equals(key))).getSingleOrNull())?.id;
  }

  /// A payment read on an account that lives here, switched to [spaceId]:
  /// the transaction there on the owner's account, a balance record here.
  Future<void> _switchAway(
    TransactionRecord tx,
    Account account,
    String spaceId, {
    int? toCategoryId,
  }) async {
    final link = _linkOf(tx);
    await _with(spaceId, (target) async {
      await target.transaction(() async {
        final owners = await ensureOwnersAccount(
          target,
          spaceId: sourceSpaceId,
          account: account,
          spaceName: await _nameOf(sourceSpaceId),
        );
        final done = await (target.select(
          target.transactions,
        )..where((t) => t.linkId.equals(link))).getSingleOrNull();
        if (done != null) return;
        final inflow = tx.direction == TransactionDirection.inflow;
        final isBusiness = await target.spaceKind() == SpaceKind.business;
        final category =
            toCategoryId ??
            await _sameCategory(target, tx) ??
            (inflow && isBusiness
                ? await ensureCategory(target, salesSeed)
                : null);
        await target
            .into(target.transactions)
            .insert(
              TransactionsCompanion.insert(
                accountId: owners,
                occurredAt: tx.occurredAt,
                amountMinor: tx.amountMinor,
                direction: tx.direction,
                kind: Value(tx.kind),
                feeMinor: Value(tx.feeMinor),
                currency: Value(tx.currency),
                fxRateMicros: Value(tx.fxRateMicros),
                fxRateCurrency: Value(tx.fxRateCurrency),
                counterpartyKind: Value(tx.counterpartyKind),
                counterpartyValue: Value(tx.counterpartyValue),
                counterpartyName: Value(tx.counterpartyName),
                item: Value(tx.item),
                categoryOverrideId: Value(category),
                receiptNo: Value(tx.receiptNo),
                source: tx.source,
                dedupeKey: Value(tx.dedupeKey),
                readBy: Value(tx.readBy),
                linkId: Value(link),
                linkedSpaceId: Value(sourceSpaceId),
              ),
            );
      });
    });

    await _source.transaction(() async {
      await ensureHeldForAccount(
        _source,
        spaceId: spaceId,
        account: account,
        spaceName: await _nameOf(spaceId),
      );
      final kept = await (_source.select(
        _source.balanceRecords,
      )..where((r) => r.linkId.equals(link))).getSingleOrNull();
      if (kept == null) {
        await _source
            .into(_source.balanceRecords)
            .insert(
              BalanceRecordsCompanion.insert(
                accountId: tx.accountId,
                occurredAt: tx.occurredAt,
                amountMinor: tx.amountMinor,
                direction: tx.direction,
                kind: Value(tx.kind),
                feeMinor: Value(tx.feeMinor),
                currency: Value(tx.currency),
                receiptNo: Value(tx.receiptNo),
                dedupeKey: Value(tx.dedupeKey),
                messageHash: Value(tx.messageHash),
                twinMessageHash: Value(tx.twinMessageHash),
                balanceAfterMinor: Value(tx.balanceAfterMinor),
                claimedBalanceMinor: Value(tx.claimedBalanceMinor),
                owedAfterMinor: Value(tx.owedAfterMinor),
                owedDueAt: Value(tx.owedDueAt),
                transactionId: Value(tx.id),
                linkId: link,
                spaceId: spaceId,
              ),
            );
      }
      await _remove(tx);
    });
  }

  /// What this space sent to Firefly III for [transactionId], if anything.
  Future<FireflySentRow?> _sentToFirefly(int transactionId) => (_source.select(
    _source.fireflySent,
  )..where((s) => s.transactionId.equals(transactionId))).getSingleOrNull();

  /// Carries [sent] over to [movedId] in [target], to be retagged in
  /// Firefly III, when [target]'s space is sent too (decision 0029), and
  /// says whether it did; otherwise it is deleted there from the space it
  /// leaves. Only a transaction that moves whole keeps its record: one
  /// switched onto the owner's account, or back, is on another account
  /// there, so it is deleted from the one space and sent from the other.
  static Future<bool> _keepInFirefly(
    AppDatabase target,
    FireflySentRow? sent,
    int movedId,
  ) async {
    if (sent == null || !await _sendsToFirefly(target)) return false;
    await target
        .into(target.fireflySent)
        .insertOnConflictUpdate(
          sent.copyWith(transactionId: movedId).toCompanion(true),
        );
    return true;
  }

  /// Whether [db]'s space is being sent to Firefly III.
  static Future<bool> _sendsToFirefly(AppDatabase db) async =>
      (await (db.select(
            db.appSettings,
          )..where((s) => s.key.equals(fireflySendingKey))).getSingleOrNull())
          ?.value ==
      'true';

  /// Removes [tx] from the open space, its messages set aside so reading
  /// them again does not bring it back. When [keptInFirefly], what was sent
  /// for it went with it, so its going leaves no delete for Firefly III.
  Future<void> _remove(
    TransactionRecord tx, {
    bool keptInFirefly = false,
  }) async {
    await setAsideMessagesOf(_source, [tx.id]);
    await unlinkLoanRepayment(_source, tx);
    // An own transfer's other half stays here, now on its own.
    await (_source.update(_source.transactions)
          ..where((t) => t.transferPairId.equals(tx.id)))
        .write(const TransactionsCompanion(transferPairId: Value(null)));
    if (keptInFirefly) {
      await (_source.delete(
        _source.fireflySent,
      )..where((s) => s.transactionId.equals(tx.id))).go();
    }
    await (_source.delete(
      _source.transactions,
    )..where((t) => t.id.equals(tx.id))).go();
  }

  /// [tx], on the owner's account [account], back to the space its account
  /// lives in: the balance record there turns back into the transaction.
  Future<void> _switchBack(
    TransactionRecord tx,
    Account account, {
    int? toCategoryId,
  }) async {
    final home = account.linkedSpaceId!;
    final link = tx.linkId;
    await _with(home, (db) async {
      await db.transaction(() async {
        final record = link == null
            ? null
            : await (db.select(
                db.balanceRecords,
              )..where((r) => r.linkId.equals(link))).getSingleOrNull();
        final accountId = record?.accountId ?? account.linkedAccountId;
        if (accountId == null ||
            await (db.select(
                  db.accounts,
                )..where((a) => a.id.equals(accountId))).getSingleOrNull() ==
                null) {
          return;
        }
        final category = toCategoryId ?? await _sameCategory(db, tx);
        final key = record?.dedupeKey ?? tx.dedupeKey;
        final already = key == null
            ? null
            : await (db.select(db.transactions)..where(
                    (t) =>
                        t.accountId.equals(accountId) & t.dedupeKey.equals(key),
                  ))
                  .getSingleOrNull();
        if (already == null) {
          await db
              .into(db.transactions)
              .insert(
                TransactionsCompanion.insert(
                  accountId: accountId,
                  occurredAt: record?.occurredAt ?? tx.occurredAt,
                  amountMinor: record?.amountMinor ?? tx.amountMinor,
                  direction: record?.direction ?? tx.direction,
                  kind: Value(record?.kind ?? tx.kind),
                  feeMinor: Value(record?.feeMinor ?? tx.feeMinor),
                  currency: Value(record?.currency ?? tx.currency),
                  fxRateMicros: Value(tx.fxRateMicros),
                  fxRateCurrency: Value(tx.fxRateCurrency),
                  counterpartyKind: Value(tx.counterpartyKind),
                  counterpartyValue: Value(tx.counterpartyValue),
                  counterpartyName: Value(tx.counterpartyName),
                  item: Value(tx.item),
                  categoryOverrideId: Value(category),
                  receiptNo: Value(record?.receiptNo ?? tx.receiptNo),
                  source: tx.source,
                  messageHash: Value(record?.messageHash),
                  twinMessageHash: Value(record?.twinMessageHash),
                  dedupeKey: Value(key),
                  balanceAfterMinor: Value(record?.balanceAfterMinor),
                  claimedBalanceMinor: Value(record?.claimedBalanceMinor),
                  owedAfterMinor: Value(record?.owedAfterMinor),
                  owedDueAt: Value(record?.owedDueAt),
                  readBy: Value(tx.readBy),
                ),
              );
        }
        final hashes = [?record?.messageHash, ?record?.twinMessageHash];
        if (hashes.isNotEmpty) {
          await (db.delete(
            db.setAsideMessages,
          )..where((m) => m.messageHash.isIn(hashes))).go();
        }
        if (key != null) {
          await (db.delete(db.movedTransactions)..where(
                (m) => m.accountId.equals(accountId) & m.dedupeKey.equals(key),
              ))
              .go();
        }
        if (record != null) {
          await (db.delete(
            db.balanceRecords,
          )..where((r) => r.id.equals(record.id))).go();
        }
      });
    });
    await (_source.delete(
      _source.transactions,
    )..where((t) => t.id.equals(tx.id))).go();
  }

  /// Whether [db]'s space reads [account]: has its institution switched on
  /// (each account is read in one space only), or, for an M-Pesa line's
  /// account, that line.
  static Future<bool> _reads(AppDatabase db, Account account) async {
    final line = lineOfReference(account.reference);
    final institution = line == null
        ? account.institutionId
        : lineSelectionId(line);
    if (institution == null) return false;
    return await (db.select(db.selectedInstitutions)
              ..where((s) => s.institutionId.equals(institution)))
            .getSingleOrNull() !=
        null;
  }

  /// A copy moved into this space before money between spaces (decision
  /// 0027), back to the space that reads its account, onto that account,
  /// with the balance its message printed.
  Future<void> _moveHome(
    TransactionRecord tx,
    Account account,
    String spaceId, {
    int? toCategoryId,
  }) async {
    final sent = await _sentToFirefly(tx.id);
    var keptInFirefly = false;
    await _with(spaceId, (target) async {
      await target.transaction(() async {
        final match =
            await (target.select(target.accounts)
                  ..where(
                    (a) =>
                        a.institutionId.equals(account.institutionId!) &
                        a.currency.equals(account.currency) &
                        (account.reference == null
                            ? a.reference.isNull()
                            : a.reference.equals(account.reference!)),
                  )
                  ..limit(1))
                .getSingleOrNull();
        final accountId =
            match?.id ??
            await target
                .into(target.accounts)
                .insert(
                  AccountsCompanion.insert(
                    name: account.name,
                    type: account.type,
                    currency: Value(account.currency),
                    openingDate: tx.occurredAt,
                    institutionId: Value(account.institutionId),
                    reference: Value(account.reference),
                  ),
                );
        final key = tx.dedupeKey;
        if (key != null &&
            await (target.select(target.transactions)..where(
                      (t) =>
                          t.accountId.equals(accountId) &
                          t.dedupeKey.equals(key),
                    ))
                    .getSingleOrNull() !=
                null) {
          return;
        }
        final movedId = await target
            .into(target.transactions)
            .insert(
              tx
                  .toCompanion(false)
                  .copyWith(
                    id: const Value.absent(),
                    accountId: Value(accountId),
                    payeeId: const Value(null),
                    goalId: const Value(null),
                    debtId: const Value(null),
                    transferPairId: const Value(null),
                    transferAccountId: const Value(null),
                    categoryOverrideId: Value(
                      toCategoryId ?? await _sameCategory(target, tx),
                    ),
                    autoCategoryId: const Value(null),
                    autoCategorySource: const Value(null),
                    autoCategoryConfidence: const Value(null),
                  ),
            );
        keptInFirefly = await _keepInFirefly(target, sent, movedId);
        final hashes = [?tx.messageHash, ?tx.twinMessageHash];
        if (hashes.isNotEmpty) {
          await (target.delete(
            target.setAsideMessages,
          )..where((m) => m.messageHash.isIn(hashes))).go();
        }
        if (key != null) {
          await (target.delete(target.movedTransactions)..where(
                (m) => m.accountId.equals(accountId) & m.dedupeKey.equals(key),
              ))
              .go();
        }
      });
    });
    await _source.transaction(() => _remove(tx, keptInFirefly: keptInFirefly));
  }

  /// One typed by hand on an account no messages are read into: it moves
  /// outright, onto the account of the same name and type there, and
  /// leaves nothing behind.
  Future<void> _moveOutright(
    TransactionRecord tx,
    Account account,
    String spaceId, {
    int? toCategoryId,
  }) async {
    final sent = await _sentToFirefly(tx.id);
    var keptInFirefly = false;
    await _with(spaceId, (target) async {
      await target.transaction(() async {
        final existing =
            await (target.select(target.accounts)..where(
                  (a) =>
                      a.name.equals(account.name) &
                      a.type.equalsValue(account.type),
                ))
                .get();
        final accountId = existing.isNotEmpty
            ? existing.first.id
            : await target
                  .into(target.accounts)
                  .insert(
                    AccountsCompanion.insert(
                      name: account.name,
                      type: account.type,
                      currency: Value(account.currency),
                      openingDate: tx.occurredAt,
                    ),
                  );
        final movedId = await target
            .into(target.transactions)
            .insert(
              tx
                  .toCompanion(false)
                  .copyWith(
                    id: const Value.absent(),
                    accountId: Value(accountId),
                    payeeId: const Value(null),
                    // Its goal and debt stay in the space it leaves.
                    goalId: const Value(null),
                    debtId: const Value(null),
                    transferPairId: const Value(null),
                    transferAccountId: const Value(null),
                    categoryOverrideId: Value(
                      toCategoryId ?? await _sameCategory(target, tx),
                    ),
                    autoCategoryId: const Value(null),
                    autoCategorySource: const Value(null),
                    autoCategoryConfidence: const Value(null),
                    linkId: const Value(null),
                    linkedSpaceId: const Value(null),
                  ),
            );
        keptInFirefly = await _keepInFirefly(target, sent, movedId);
      });
    });
    await _source.transaction(() => _remove(tx, keptInFirefly: keptInFirefly));
  }

  @override
  Future<void> forMe(int transactionId, {int? personalCategoryId}) async {
    final tx = await (_source.select(
      _source.transactions,
    )..where((t) => t.id.equals(transactionId))).getSingleOrNull();
    if (tx == null || tx.direction != TransactionDirection.outflow) return;
    if (sourceSpaceId == personalSpaceId) return;
    final link = 'forMe:$sourceSpaceId:${tx.id}';
    await _with(personalSpaceId, (personal) async {
      await personal.transaction(() async {
        final paidBy = await ensurePaidByAccount(
          personal,
          spaceId: sourceSpaceId,
          spaceName: await _nameOf(sourceSpaceId),
        );
        final done = await (personal.select(
          personal.transactions,
        )..where((t) => t.linkId.equals(link))).getSingleOrNull();
        if (done != null) return;
        await personal
            .into(personal.transactions)
            .insert(
              TransactionsCompanion.insert(
                accountId: paidBy,
                occurredAt: tx.occurredAt,
                // What was bought; the fee stays the business's.
                amountMinor: tx.amountMinor,
                direction: TransactionDirection.outflow,
                kind: Value(tx.kind),
                currency: Value(tx.currency),
                fxRateMicros: Value(tx.fxRateMicros),
                fxRateCurrency: Value(tx.fxRateCurrency),
                counterpartyKind: Value(tx.counterpartyKind),
                counterpartyValue: Value(tx.counterpartyValue),
                counterpartyName: Value(tx.counterpartyName),
                item: Value(tx.item),
                categoryOverrideId: Value(personalCategoryId),
                receiptNo: Value(tx.receiptNo),
                source: TransactionSource.manual,
                linkId: Value(link),
                linkedSpaceId: Value(sourceSpaceId),
              ),
            );
      });
    });
    await (_source.update(
      _source.transactions,
    )..where((t) => t.id.equals(tx.id))).write(
      TransactionsCompanion(
        categoryOverrideId: Value(await ensureCategory(_source, ownerPaySeed)),
        linkId: Value(link),
        linkedSpaceId: const Value(personalSpaceId),
      ),
    );
  }

  @override
  Future<void> forTheBusiness(int transactionId, {int? costCategoryId}) async {
    final tx = await (_source.select(
      _source.transactions,
    )..where((t) => t.id.equals(transactionId))).getSingleOrNull();
    final link = tx?.linkId;
    final other = tx?.linkedSpaceId;
    if (tx == null || link == null || other == null) return;
    final account = await _accountOf(_source, tx.accountId);
    if (account.type == AccountType.paidBySpace) {
      // From Personal: the purchase goes, the business's Paid yourself
      // becomes a cost.
      await _with(other, (business) async {
        await (business.update(
          business.transactions,
        )..where((t) => t.linkId.equals(link))).write(
          TransactionsCompanion(
            categoryOverrideId: Value(costCategoryId),
            linkId: const Value(null),
            linkedSpaceId: const Value(null),
          ),
        );
      });
      await (_source.delete(
        _source.transactions,
      )..where((t) => t.id.equals(tx.id))).go();
      return;
    }
    // From the business: Personal's purchase goes.
    await _with(other, (personal) async {
      await (personal.delete(
        personal.transactions,
      )..where((t) => t.linkId.equals(link))).go();
    });
    await (_source.update(
      _source.transactions,
    )..where((t) => t.id.equals(tx.id))).write(
      TransactionsCompanion(
        categoryOverrideId: Value(costCategoryId),
        linkId: const Value(null),
        linkedSpaceId: const Value(null),
      ),
    );
  }
}

/// The owner's account in [db] for [spaceId]'s [account] (decision 0027):
/// where [db]'s money on that account is kept, "Your M-Pesa". Made when
/// first needed.
Future<int> ensureOwnersAccount(
  AppDatabase db, {
  required String spaceId,
  required Account account,
  required String spaceName,
}) async {
  final existing =
      await (db.select(db.accounts)..where(
            (a) =>
                a.type.equalsValue(AccountType.ownersAccount) &
                a.linkedSpaceId.equals(spaceId) &
                a.linkedAccountId.equals(account.id),
          ))
          .getSingleOrNull();
  if (existing != null) return existing.id;
  final name = spaceId == personalSpaceId
      ? 'Your ${account.name}'
      : "$spaceName's ${account.name}";
  return db
      .into(db.accounts)
      .insert(
        AccountsCompanion.insert(
          name: name.length > 80 ? name.substring(0, 80) : name,
          type: AccountType.ownersAccount,
          currency: Value(account.currency),
          openingDate: DateTime.utc(1970),
          linkedSpaceId: Value(spaceId),
          linkedAccountId: Value(account.id),
        ),
      );
}

/// Held for [spaceId] on [account] in [db], where the account lives:
/// "Held for Vegetable stall". Made when first needed.
Future<int> ensureHeldForAccount(
  AppDatabase db, {
  required String spaceId,
  required Account account,
  required String spaceName,
}) async {
  final existing =
      await (db.select(db.accounts)..where(
            (a) =>
                a.type.equalsValue(AccountType.heldForSpace) &
                a.linkedSpaceId.equals(spaceId) &
                a.linkedAccountId.equals(account.id),
          ))
          .getSingleOrNull();
  if (existing != null) return existing.id;
  final name = 'Held for $spaceName';
  return db
      .into(db.accounts)
      .insert(
        AccountsCompanion.insert(
          name: name.length > 80 ? name.substring(0, 80) : name,
          type: AccountType.heldForSpace,
          currency: Value(account.currency),
          openingDate: DateTime.utc(1970),
          linkedSpaceId: Value(spaceId),
          linkedAccountId: Value(account.id),
        ),
      );
}

/// Paid by [spaceId] in Personal's [db]: where a purchase with that
/// space's money sits, "Paid from Vegetable stall". Made when first needed.
Future<int> ensurePaidByAccount(
  AppDatabase db, {
  required String spaceId,
  required String spaceName,
}) async {
  final existing =
      await (db.select(db.accounts)..where(
            (a) =>
                a.type.equalsValue(AccountType.paidBySpace) &
                a.linkedSpaceId.equals(spaceId),
          ))
          .getSingleOrNull();
  if (existing != null) return existing.id;
  return db
      .into(db.accounts)
      .insert(
        AccountsCompanion.insert(
          name: spaceName.length > 80 ? spaceName.substring(0, 80) : spaceName,
          type: AccountType.paidBySpace,
          openingDate: DateTime.utc(1970),
          linkedSpaceId: Value(spaceId),
        ),
      );
}

final spaceMoveRepositoryProvider = Provider<SpaceMoveRepository>((ref) {
  final spaces = ref.watch(spaceDatabasesProvider);
  return DriftSpaceMoveRepository(
    ref.watch(appDatabaseProvider),
    // Only a space on the list: see [SpaceDatabases.open].
    spaces.open,
    sourceSpaceId: ref.watch(activeSpaceIdProvider),
    nameOf: spaces.nameOf,
  );
});
