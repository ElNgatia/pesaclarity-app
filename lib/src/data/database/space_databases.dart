import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/spaces/space.dart';
import '../repositories/app_settings_repository.dart';
import 'app_database.dart';
import 'connection.dart';
import 'database_providers.dart';

/// Where Personal's settings keep the list of spaces on this phone.
const spacesListKey = 'spaces.list';

/// Where Personal's settings keep what is in Recently deleted, with the
/// keys of the locked copies.
const keptSpacesKey = 'spaces.kept';

/// Where Personal's settings keep the Business or personal rules.
const routingRulesKey = 'routing.rules';

/// Personal's settings that are about every space, not Personal's own
/// records: which spaces exist, what is kept of deleted ones, and where
/// money goes between them. A restore of Personal leaves them as they are
/// (see `LocalDataStore.replaceWith`).
const everySpaceSettingKeys = {spacesListKey, keptSpacesKey, routingRulesKey};

/// Something asked for a space that is not on this phone's list, such as a
/// business deleted since a rule was made for it.
final class SpaceNotOnPhone implements Exception {
  const SpaceNotOnPhone(this.spaceId);

  final String spaceId;

  @override
  String toString() => 'SpaceNotOnPhone: $spaceId is not on the list';
}

/// The databases of the spaces on this phone, for work that reaches beyond
/// the open one: a move to another space, a backup copy, clearing a space.
///
/// Every such open goes through here, so nothing is ever moved into, and no
/// file is ever made for, a space that is not on the list.
class SpaceDatabases {
  SpaceDatabases(this._ref);

  final Ref _ref;

  /// Every space on this phone, Personal first, as Personal's settings list
  /// them now.
  Future<List<Space>> listed() async => spacesFromJson(
    await DriftAppSettingsRepository(_ref.read(mainDatabaseProvider))
        .readJson(spacesListKey),
  );

  /// [spaceId]'s database, and whether the caller must close it.
  ///
  /// Throws [SpaceNotOnPhone], touching no file, when the space is not on
  /// the list.
  Future<(AppDatabase, bool)> open(String spaceId) async {
    if (spaceId != personalSpaceId &&
        !(await listed()).any((space) => space.id == spaceId)) {
      throw SpaceNotOnPhone(spaceId);
    }
    if (spaceId == _ref.read(activeSpaceIdProvider)) {
      return (_ref.read(appDatabaseProvider), false);
    }
    if (spaceId == personalSpaceId) {
      return (_ref.read(personalDatabaseProvider), false);
    }
    return (
      openEncryptedDatabase(
        _ref.read(databaseKeyStoreProvider),
        beforeOpen: _ref.read(databaseFileLockProvider).waitUntilFree,
        spaceId: spaceId,
      ),
      true,
    );
  }

  /// The other space on the list that reads [institutionId] (has it
  /// switched on), Personal first; null when the open space is the only one
  /// that could. Each account is read in one space, so a second never
  /// switches it on.
  Future<Space?> readerOf(String institutionId) async {
    final open = _ref.read(activeSpaceIdProvider);
    for (final space in await listed()) {
      if (space.id == open) continue;
      final (db, close) = await this.open(space.id);
      try {
        final row =
            await (db.select(db.selectedInstitutions)
                  ..where((s) => s.institutionId.equals(institutionId)))
                .getSingleOrNull();
        if (row != null) return space;
      } finally {
        if (close) await db.close();
      }
    }
    return null;
  }

  /// Each institution another space on the list reads, with the first
  /// space that reads it, Personal first. Empty when only the open space
  /// reads anything.
  Future<Map<String, Space>> readers() async {
    final open = _ref.read(activeSpaceIdProvider);
    final found = <String, Space>{};
    for (final space in await listed()) {
      if (space.id == open) continue;
      final (db, close) = await this.open(space.id);
      try {
        for (final row in await db.select(db.selectedInstitutions).get()) {
          found.putIfAbsent(row.institutionId, () => space);
        }
      } finally {
        if (close) await db.close();
      }
    }
    return found;
  }

  /// Which of [hashes] another space on the list already holds as a
  /// transaction, the message's own or as its twin. Each message lands in
  /// one space only: the one that read it first, or the one the person
  /// moved it to. A space that cannot be opened is skipped, so reading
  /// never stops for it.
  Future<Set<String>> heldElsewhere(Set<String> hashes) async {
    if (hashes.isEmpty) return const {};
    final open = _ref.read(activeSpaceIdProvider);
    final others = [
      for (final space in await listed())
        if (space.id != open) space.id,
    ];
    final found = <String>{};
    for (final id in others) {
      try {
        final (db, close) = await this.open(id);
        try {
          found.addAll(await heldIn(db, hashes));
        } finally {
          if (close) await db.close();
        }
      } on Object catch (error) {
        if (kDebugMode) debugPrint('Could not look in $id: $error');
      }
    }
    return found;
  }
}

/// Which of [hashes] [db] holds as a transaction's message or its twin.
Future<Set<String>> heldIn(AppDatabase db, Set<String> hashes) async {
  final t = db.transactions;
  final list = hashes.toList();
  final found = <String>{};
  for (var i = 0; i < list.length; i += 400) {
    final chunk = list.sublist(
      i,
      i + 400 > list.length ? list.length : i + 400,
    );
    final rows =
        await (db.selectOnly(t)
              ..addColumns([t.messageHash, t.twinMessageHash])
              ..where(
                t.messageHash.isIn(chunk) | t.twinMessageHash.isIn(chunk),
              ))
            .get();
    for (final row in rows) {
      for (final hash in [
        row.read(t.messageHash),
        row.read(t.twinMessageHash),
      ]) {
        if (hash != null && hashes.contains(hash)) found.add(hash);
      }
    }
  }
  return found;
}

final spaceDatabasesProvider = Provider<SpaceDatabases>(SpaceDatabases.new);
