import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/time/clock.dart';
import '../../../data/database/app_database.dart';
import '../../../data/database/database_providers.dart';
import '../../../data/database/space_databases.dart';
import '../../../data/repositories/app_settings_repository.dart';
import '../../../data/repositories/balances_repair.dart';
import '../../../data/repositories/category_seeds.dart';
import '../../../data/repositories/journal_repository.dart';
import '../../../data/repositories/message_reads_repository.dart';
import '../../../data/repositories/money_repair.dart';
import '../../../data/repositories/restore_check.dart';
import '../../../data/repositories/savings_links.dart';
import '../../../domain/spaces/kept_data.dart';
import '../../../domain/spaces/space.dart';
import '../../../domain/spaces/space_categories.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/auth_models.dart';
import '../../backup/application/backup_providers.dart';
import '../../backup/data/local_database_backup.dart';
import '../data/space_files.dart';
import 'routing_providers.dart';
import 'spaces_providers.dart';

/// Tables a space keeps when its data is cleared: its settings, accounts and
/// categories. Every other table is its records.
const _keptOnClear = {
  'app_settings',
  // Cleared records stay cleared when messages are read again.
  'set_aside_messages',
  'accounts',
  'categories',
  'tags',
  'selected_institutions',
  'parser_packs',
  'reader_templates',
  'rate_snapshots',
  // A savings account keeps its goals, as it is kept itself.
  'savings_pockets',
};

/// Data kept for 30 days, newest first, from Personal's settings.
class KeptDataController extends AsyncNotifier<List<KeptData>> {
  static const settingsKey = keptSpacesKey;

  @override
  Future<List<KeptData>> build() async {
    final kept = keptFromJson(
      await ref.watch(mainSettingsRepositoryProvider).readJson(settingsKey),
    )..sort((a, b) => b.removedAt.compareTo(a.removedAt));
    return kept;
  }

  Future<void> save(List<KeptData> kept) async {
    await ref
        .read(mainSettingsRepositoryProvider)
        .writeJson(settingsKey, keptToJson(kept));
    state = AsyncData(kept);
  }
}

final keptDataProvider =
    AsyncNotifierProvider<KeptDataController, List<KeptData>>(
      KeptDataController.new,
    );

/// The owner's answer when what Clear data takes holds a business's money
/// on the owner's accounts (decision 0027, owner's decision 9).
enum HeldOnClear {
  /// "It is mine now": filed as pay from the business.
  mine,

  /// "Keep it apart": the business keeps it as an opening amount.
  apart,
}

/// Clears, deletes and restores spaces. Each space's data stays in its own
/// locked file: nothing is copied from one space to another.
class SpaceManager {
  SpaceManager(this._ref);

  final Ref _ref;

  DateTime get _now => _ref.read(clockProvider)();

  /// [space]'s database, and whether the caller must close it. Only a space
  /// on the list: see [SpaceDatabases.open].
  Future<(AppDatabase, bool)> _open(String spaceId) =>
      _ref.read(spaceDatabasesProvider).open(spaceId);

  /// A locked copy of [space] for 30 days.
  Future<void> _keep(Space space, KeptKind kind) async {
    final token = _token();
    final dir = await _ref.read(spaceFilesProvider).keptDirectory();
    final (db, close) = await _open(space.id);
    final String key;
    try {
      key = await exportDatabase(db, File(p.join(dir.path, '$token.sqlite')));
    } finally {
      if (close) await db.close();
    }
    final kept = await _ref.read(keptDataProvider.future);
    await _ref.read(keptDataProvider.notifier).save([
      KeptData(
        token: token,
        kind: kind,
        space: space,
        removedAt: _now,
        keyHex: key,
        // A deleted space's rules wait with its copy, out of use.
        rules: kind == KeptKind.space
            ? (await _ref.read(routingRulesProvider.future)).forSpace(space.id)
            : null,
      ),
      ...kept,
    ]);
  }

  /// Keeps a locked copy of every space for 30 days, then runs the one-time
  /// repair of money between spaces (decision 0027, section 8), and saves
  /// what it did for the sheet that tells the person. Runs once: nothing
  /// to repair, it is only marked done.
  ///
  /// The repair of messages stored in two spaces ([repairSpaceLeakOnce])
  /// runs first, in every space that has not run it yet: it takes out the
  /// copies, and what it keeps on purpose it leaves as a move, so the
  /// moves this repair then turns into the owner's account are only moves,
  /// each once. Should a space not open, neither runs, and both run again
  /// the next time.
  Future<MoneyRepairState> repairMoneyBetweenSpaces() async {
    final personal = _ref.read(personalDatabaseProvider);
    final store = MoneyRepairStore(personal);
    final state = await store.read();
    if (state.ran) return state;
    final spaces = await _ref.read(spaceDatabasesProvider).listed();
    final ids = [for (final space in spaces) space.id];
    for (final id in ids) {
      final (db, close) = await _open(id);
      try {
        await repairSpaceLeakOnce(db, (here: id, ids: ids, open: _open));
      } finally {
        if (close) await db.close();
      }
    }
    final repair = MoneyRepair(
      personal: personal,
      spaces: spaces.isEmpty ? [Space.personal] : spaces,
      open: _open,
    );
    if (!await repair.needed()) {
      const done = MoneyRepairState(ran: true, shown: true);
      await store.save(done);
      return done;
    }
    for (final space in spaces) {
      await _keep(space, KeptKind.beforeRepair);
    }
    final result = await repair.run();
    final done = MoneyRepairState(ran: true, result: result);
    await store.save(done);
    return done;
  }

  /// Makes [space] a [kind] of space, open or not. Its records stay.
  Future<void> changeKind(Space space, SpaceKind kind) async {
    final (db, close) = await _open(space.id);
    try {
      await _ref.read(spacesProvider.notifier).changeKind(space.id, kind, db);
    } finally {
      if (close) await db.close();
    }
  }

  /// Removes [space]'s records, keeping the space, its accounts, categories
  /// and settings. With [keep], a locked copy stays for 30 days.
  ///
  /// With [from] and [to], only what happened in that range goes: its
  /// transactions, sales and quick records; everything else stays.
  ///
  /// When what is cleared holds a business's money on the owner's
  /// accounts (decision 0027, owner's decision 9), [held] is the owner's
  /// answer: "It is mine now" files it in Personal as pay from the
  /// business; "Keep it apart" keeps it on the business's owner's accounts
  /// as their opening amount, so both sides still agree.
  ///
  /// Returns whether the online copies, with [deleteOnline], wait for a
  /// connection; being offline never stops what happens on the phone.
  Future<bool> clear(
    Space space, {
    required bool keep,
    bool deleteOnline = false,
    DateTime? from,
    DateTime? to,
    HeldOnClear? held,
  }) async {
    if (keep) await _keep(space, KeptKind.cleared);
    final (db, close) = await _open(space.id);
    try {
      final range = from != null && to != null;
      final parts = held == null || space.id == personalSpaceId
          ? const <int, int>{}
          : await ownersPartIn(
              db,
              from: range ? from : null,
              to: range ? to : null,
            );
      if (held == HeldOnClear.mine) {
        final personal = _ref.read(personalDatabaseProvider);
        final pay = await ensureCategory(personal, payFromBusinessSeed);
        if (range) {
          await settleHeldPart(
            personal: personal,
            business: db,
            spaceId: space.id,
            spaceName: space.name,
            parts: parts,
            payCategoryId: pay,
            at: _now,
          );
        } else {
          await settleHeldFor(
            personal,
            spaceId: space.id,
            spaceName: space.name,
            payCategoryId: pay,
            at: _now,
          );
        }
      }
      if (range) {
        await _clearRange(db, from, to);
        if (held == HeldOnClear.apart) await keepOwnersPart(db, parts);
        return false;
      }
      await db.customStatement('PRAGMA foreign_keys = OFF');
      try {
        await db.transaction(() async {
          await setAsideMessagesOf(
            db,
            await db.select(db.transactions).map((t) => t.id).get(),
          );
          for (final table in db.allTables) {
            if (_keptOnClear.contains(table.actualTableName)) continue;
            await db.delete(table).go();
          }
          if (held == HeldOnClear.apart) await keepOwnersPart(db, parts);
          // The journal went with the records: post it again from the
          // accounts kept, each with its opening balance.
          await JournalRepository.markForRebuild(db);
        });
      } finally {
        await db.customStatement('PRAGMA foreign_keys = ON');
      }
    } finally {
      if (close) await db.close();
    }
    return deleteOnline && await _deleteOnline(space.id);
  }

  /// Removes what happened from [from] up to [to] in [db]. Rows that point
  /// at what goes let go of it, as the database's own rules say.
  Future<void> _clearRange(AppDatabase db, DateTime from, DateTime to) =>
      db.transaction(() async {
        final ids = [
          for (final t
              in await (db.select(db.transactions)..where(
                    (t) =>
                        t.occurredAt.isBiggerOrEqualValue(from) &
                        t.occurredAt.isSmallerThanValue(to),
                  ))
                  .get())
            t.id,
        ];
        if (ids.isNotEmpty) {
          await setAsideMessagesOf(db, ids);
          await (db.update(db.transactions)
                ..where((t) => t.transferPairId.isIn(ids)))
              .write(const TransactionsCompanion(transferPairId: Value(null)));
          await (db.delete(db.transactions)..where((t) => t.id.isIn(ids))).go();
        }
        await (db.delete(db.sales)..where(
              (s) =>
                  s.soldAt.isBiggerOrEqualValue(from) &
                  s.soldAt.isSmallerThanValue(to),
            ))
            .go();
        await (db.delete(db.quickRecords)..where(
              (q) =>
                  q.at.isBiggerOrEqualValue(from) & q.at.isSmallerThanValue(to),
            ))
            .go();
        await clearSavingsRange(db, from, to);
      });

  /// Deletes [space] and everything in it from this phone. With [keep], a
  /// locked copy stays for 30 days. Personal is never deleted on its own.
  ///
  /// Returns whether the online copies, with [deleteOnline], wait for a
  /// connection; being offline never stops what happens on the phone.
  Future<bool> delete(
    Space space, {
    required bool keep,
    bool deleteOnline = false,
  }) async {
    if (space.id == personalSpaceId) {
      throw ArgumentError('Personal is deleted with Delete all my data.');
    }
    if (keep) await _keep(space, KeptKind.space);
    if (_ref.read(activeSpaceIdProvider) == space.id) {
      final open = _ref.read(appDatabaseProvider);
      await _ref.read(activeSpaceIdProvider.notifier).switchTo(personalSpaceId);
      await _ref.read(databaseFileLockProvider).close(open);
    }
    if (_ref.read(openSpaceChoiceProvider) == space.id) {
      await _ref.read(openSpaceChoiceProvider.notifier).choose(openLastSpace);
    }
    await _ref.read(spaceFilesProvider).deleteDatabase(space.id);
    await _ref.read(spacesProvider.notifier).remove(space.id);
    // Its rules go with it, so nothing is sent to a space that is gone.
    await _ref.read(routingRulesProvider.notifier).forgetSpace(space.id);
    return deleteOnline && await _deleteOnline(space.id);
  }

  /// Deletes [spaceId]'s online copies now or once online; true if they
  /// wait.
  Future<bool> _deleteOnline(String spaceId) =>
      _ref.read(backupControllerProvider.notifier).deleteOnlineCopies(spaceId);

  /// Puts [kept] back: a cleared space gets its records again, a deleted
  /// space comes back as it was. The space opens.
  Future<void> restore(KeptData kept) async {
    final file = await _file(kept);
    await _ref.read(spacesProvider.notifier).putBack(kept.space);
    await _ref.read(routingRulesProvider.notifier).putBack(kept.rules);
    await _ref.read(activeSpaceIdProvider.notifier).switchTo(kept.space.id);
    // Restoring replaces the file, so it must not be needed afterwards.
    final staged = File('${file.path}.restoring');
    await file.copy(staged.path);
    await _ref
        .read(localDataStoreProvider)
        .replaceWith(staged, kept.keyHex, ofSpace: kept.space.id);
    // Checks once whether a payment between spaces lost a side (decision
    // 0027, section 7).
    await RestoreCheck.mark(_ref.read(appDatabaseProvider), kept.removedAt);
    await _forget(kept);
  }

  /// Removes [kept] for good now.
  Future<void> deleteNow(KeptData kept) => _forget(kept);

  /// Removes everything kept longer than 30 days.
  Future<void> purgeExpired() async {
    final now = _now;
    for (final kept in await _ref.read(keptDataProvider.future)) {
      if (kept.expiredAt(now)) await _forget(kept);
    }
  }

  Future<void> _forget(KeptData kept) async {
    final file = await _file(kept);
    if (file.existsSync()) await file.delete();
    final staged = File('${file.path}.restoring');
    if (staged.existsSync()) await staged.delete();
    final list = await _ref.read(keptDataProvider.future);
    await _ref.read(keptDataProvider.notifier).save([
      for (final k in list)
        if (k.token != kept.token) k,
    ]);
  }

  Future<File> _file(KeptData kept) async => File(
    p.join(
      (await _ref.read(spaceFilesProvider).keptDirectory()).path,
      '${kept.token}.sqlite',
    ),
  );

  /// Deletes every space and everything the app keeps on this phone, at
  /// once. Online backups and the sign-in go too when asked, if the server
  /// can be reached; nothing is kept to do it later, so what could not be
  /// done online is returned. Being offline never stops the deleting here.
  Future<DeleteEverythingResult> deleteEverything({
    required bool deleteOnline,
    required bool deleteSignIn,
  }) async {
    var onlineCopiesLeft = false;
    if (deleteOnline) {
      final backups = _ref.read(backupControllerProvider.notifier);
      for (final space in await _ref.read(spacesProvider.future)) {
        if ((await backups.deleteOnlineBackups(space.id)).isNotEmpty) {
          onlineCopiesLeft = true;
        }
      }
    }
    AuthFailure? signInLeft;
    if (deleteSignIn) {
      try {
        await _ref.read(authControllerProvider.notifier).deleteAccount();
      } on AuthFailure catch (failure) {
        signInLeft = failure;
      }
    }
    final lock = _ref.read(databaseFileLockProvider);
    await lock.close(_ref.read(appDatabaseProvider));
    await lock.close(_ref.read(personalDatabaseProvider));
    await _ref.read(spaceFilesProvider).eraseEverything();
    return DeleteEverythingResult(
      onlineCopiesLeft: onlineCopiesLeft,
      signInLeft: signInLeft,
    );
  }

  static String _token() {
    final random = Random.secure();
    return List.generate(
      24,
      (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[random.nextInt(36)],
    ).join();
  }
}

final spaceManagerProvider = Provider<SpaceManager>(SpaceManager.new);

/// What [SpaceManager.deleteEverything] could not do online.
final class DeleteEverythingResult {
  const DeleteEverythingResult({
    this.onlineCopiesLeft = false,
    this.signInLeft,
  });

  /// Whether online backups could not all be deleted.
  final bool onlineCopiesLeft;

  /// Why the sign-in could not be deleted, when asked and it failed.
  final AuthFailure? signInLeft;
}
