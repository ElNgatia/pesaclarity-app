import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../data/database/app_database.dart';
import '../../../data/repositories/firefly_triggers.dart';

/// One space's Firefly III bookkeeping, in its own database: whether it is
/// being sent, its outbox, what was sent and to which accounts (decision
/// 0029, sections 4 and 5).
class FireflySpaceStore {
  FireflySpaceStore(this.db);

  final AppDatabase db;

  /// Whether this space is being sent.
  Future<bool> sending() async {
    final row = await (db.select(
      db.appSettings,
    )..where((s) => s.key.equals(fireflySendingKey))).getSingleOrNull();
    return row?.value == 'true';
  }

  /// Starts or stops sending this space. Stopping drops what waits to be
  /// sent; what was sent stays, and so does the record of it.
  Future<void> setSending(bool on) => db.transaction(() async {
    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: fireflySendingKey,
            value: on ? 'true' : 'false',
          ),
        );
    if (!on) await db.delete(db.fireflyOutbox).go();
  });

  /// Rows waiting, refused ones included.
  Future<int> waitingCount() async {
    final count = db.fireflyOutbox.transactionId.count();
    final row = await (db.selectOnly(
      db.fireflyOutbox,
    )..addColumns([count])).getSingle();
    return row.read(count) ?? 0;
  }

  /// Rows Firefly III refused, with why.
  Future<List<FireflyOutboxRow>> refused() =>
      (db.select(db.fireflyOutbox)..where((o) => o.refused.equals(true))).get();

  /// Rows due to be sent at [now], oldest first: not refused, and past any
  /// back-off.
  Future<List<FireflyOutboxRow>> due(DateTime now, {int? limit}) {
    final query = db.select(db.fireflyOutbox)
      ..where(
        (o) =>
            o.refused.equals(false) &
            (o.nextTryAt.isNull() | o.nextTryAt.isSmallerOrEqualValue(now)),
      )
      ..orderBy([
        (o) => OrderingTerm.asc(o.queuedAt),
        (o) => OrderingTerm.asc(o.transactionId),
      ]);
    if (limit != null) query.limit(limit);
    return query.get();
  }

  /// Queues [transactionId] to be sent, or deleted there, replacing what
  /// waited for it (the latest change wins).
  Future<void> queue(int transactionId, {bool delete = false, DateTime? at}) =>
      db
          .into(db.fireflyOutbox)
          .insertOnConflictUpdate(
            FireflyOutboxCompanion.insert(
              transactionId: Value(transactionId),
              action: delete ? 'delete' : 'send',
              queuedAt: at ?? DateTime.now(),
              attempts: const Value(0),
              lastError: const Value(null),
              refused: const Value(false),
              nextTryAt: const Value(null),
            ),
          );

  /// Done with [row]: removed unless a newer change replaced it meanwhile.
  Future<void> done(FireflyOutboxRow row) =>
      (db.delete(db.fireflyOutbox)..where(
            (o) =>
                o.transactionId.equals(row.transactionId) &
                o.queuedAt.equals(row.queuedAt) &
                o.action.equals(row.action),
          ))
          .go();

  /// Firefly III refused [row]: kept, with [reason], until the next change.
  Future<void> refuse(FireflyOutboxRow row, String reason) =>
      (db.update(db.fireflyOutbox)..where(
            (o) =>
                o.transactionId.equals(row.transactionId) &
                o.queuedAt.equals(row.queuedAt),
          ))
          .write(
            FireflyOutboxCompanion(
              refused: const Value(true),
              lastError: Value(reason),
              attempts: Value(row.attempts + 1),
            ),
          );

  /// [row] failed for now: tried again after [retryAt].
  Future<void> backOff(FireflyOutboxRow row, String reason, DateTime retryAt) =>
      (db.update(db.fireflyOutbox)..where(
            (o) =>
                o.transactionId.equals(row.transactionId) &
                o.queuedAt.equals(row.queuedAt),
          ))
          .write(
            FireflyOutboxCompanion(
              lastError: Value(reason),
              attempts: Value(row.attempts + 1),
              nextTryAt: Value(retryAt),
            ),
          );

  /// Drops every waiting row.
  Future<void> clearOutbox() => db.delete(db.fireflyOutbox).go();

  /// What was sent for [transactionId], if anything.
  Future<FireflySentRow?> sent(int transactionId) => (db.select(
    db.fireflySent,
  )..where((s) => s.transactionId.equals(transactionId))).getSingleOrNull();

  /// Everything sent, by transaction id.
  Future<Map<int, FireflySentRow>> allSent() async => {
    for (final row in await db.select(db.fireflySent).get())
      row.transactionId: row,
  };

  /// Records what was sent for [transactionId]: each part's group id and
  /// the fields last sent for it, by suffix.
  Future<void> recordSent({
    required int transactionId,
    required String externalId,
    required Map<String, SentGroup> groups,
    required String hash,
    required DateTime at,
    bool removedThere = false,
  }) => db
      .into(db.fireflySent)
      .insertOnConflictUpdate(
        FireflySentCompanion.insert(
          transactionId: Value(transactionId),
          externalId: externalId,
          groups: jsonEncode({
            for (final MapEntry(:key, :value) in groups.entries)
              key: {'id': value.id, 'fields': value.fields},
          }),
          hash: hash,
          removedThere: Value(removedThere),
          sentAt: at,
        ),
      );

  /// Forgets what was sent for [transactionId].
  Future<void> forgetSent(int transactionId) => (db.delete(
    db.fireflySent,
  )..where((s) => s.transactionId.equals(transactionId))).go();

  /// Clears every "removed there" mark, for Send everything again: those
  /// transactions are made there anew.
  Future<void> clearRemovedThere() =>
      (db.update(
        db.fireflySent,
      )..where((s) => s.removedThere.equals(true))).write(
        const FireflySentCompanion(
          removedThere: Value(false),
          groups: Value('{}'),
          hash: Value(''),
        ),
      );

  /// The Firefly III account [key] was sent to.
  Future<FireflyAccountRow?> account(String key) => (db.select(
    db.fireflyAccounts,
  )..where((a) => a.key.equals(key))).getSingleOrNull();

  Future<void> recordAccount({
    required String key,
    required String fireflyId,
    required String name,
    String? opening,
  }) => db
      .into(db.fireflyAccounts)
      .insertOnConflictUpdate(
        FireflyAccountsCompanion.insert(
          key: key,
          fireflyId: fireflyId,
          name: name,
          opening: Value(opening),
        ),
      );

  Future<void> forgetAccount(String key) =>
      (db.delete(db.fireflyAccounts)..where((a) => a.key.equals(key))).go();

  Future<List<FireflyAccountRow>> accounts() =>
      db.select(db.fireflyAccounts).get();
}

/// One part of a transaction as sent: its Firefly III group, and the
/// fields last sent for it, so an edit sends only what changed.
typedef SentGroup = ({String id, Map<String, Object?> fields});

/// Each part of [row] as sent, by suffix.
Map<String, SentGroup> sentGroups(FireflySentRow row) {
  final Object? json;
  try {
    json = jsonDecode(row.groups);
  } on FormatException {
    return const {};
  }
  if (json is! Map) return const {};
  return {
    for (final MapEntry(:key, :value) in json.entries)
      if (key is String && value is Map && value['id'] is String)
        key: (
          id: value['id'] as String,
          fields: value['fields'] is Map
              ? Map<String, Object?>.from(value['fields'] as Map)
              : const <String, Object?>{},
        ),
  };
}
