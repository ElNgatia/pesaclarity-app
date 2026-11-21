import 'dart:async';
import 'dart:math';

import '../../../core/money/money.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/firefly/firefly_mapping.dart';
import '../../../domain/spaces/space.dart';
import '../data/firefly_client.dart';
import '../data/firefly_space_reader.dart';
import '../data/firefly_space_store.dart';

/// What one space's send did.
class FireflySpaceReport {
  const FireflySpaceReport({
    this.sent = 0,
    this.deleted = 0,
    this.refused = 0,
    this.waiting = 0,
  });

  /// Transactions made or changed in Firefly III.
  final int sent;

  /// Transactions deleted there.
  final int deleted;

  /// Transactions Firefly III refused this time.
  final int refused;

  /// Changes still waiting afterwards, refused ones included.
  final int waiting;
}

/// An account whose balance in Firefly III is not what Pesa Clarity's
/// journal says (decision 0029, section 8).
class FireflyBalanceDifference {
  const FireflyBalanceDifference({
    required this.key,
    required this.name,
    required this.expectedMinor,
    required this.thereMinor,
  });

  final String key;
  final String name;

  /// An asset's balance or what a liability says is owed, in Pesa Clarity.
  final int expectedMinor;

  /// The same in Firefly III; null when it could not be read.
  final int? thereMinor;

  @override
  String toString() =>
      'FireflyBalanceDifference($name: here $expectedMinor, '
      'there $thereMinor)';
}

/// Sends spaces to Firefly III (decision 0029, sections 3 to 5): first a
/// check by hash that queues whatever no single change queued, then the
/// outbox in order, each transaction's accounts first, a few at a time
/// with a short pause so a small home server is not flooded.
///
/// A problem with the server itself (out of reach, the token refused, a
/// certificate or address problem) stops the run and is thrown; it is
/// tried again next time. A transaction Firefly III refuses is kept with
/// its reason and skipped until it changes; one that fails for now backs
/// off.
class FireflySender {
  FireflySender({
    required this.client,
    required this.from,
    required this.offset,
    DateTime Function()? clock,
    this.batch = 10,
    this.pause = const Duration(milliseconds: 400),
  }) : _clock = clock ?? DateTime.now;

  final FireflyClient client;

  /// The start of the Send from day: nothing earlier is sent, and every
  /// account opens with its balance at this moment.
  final DateTime from;

  /// The person's time zone, which dates carry.
  final Duration offset;
  final DateTime Function() _clock;

  /// How many transactions go before each [pause].
  final int batch;
  final Duration pause;

  final _currencies = <String>{};

  /// The Send from day as Firefly III reads an opening date.
  String get _openingDate => fireflyDate(from, offset).substring(0, 10);

  /// Sends [space], kept in [db], when it is being sent. With [resendAll],
  /// transactions the person deleted in Firefly III are sent again.
  Future<FireflySpaceReport> sendSpace(
    Space space,
    AppDatabase db, {
    bool resendAll = false,
  }) async {
    final store = FireflySpaceStore(db);
    if (!await store.sending()) return const FireflySpaceReport();
    if (resendAll) await store.clearRemovedThere();
    final snapshot = await readFireflySpace(db, space: space, from: from);
    final sent = await store.allSent();
    await _queueDifferences(store, snapshot, sent);

    // With no record of what was sent (the first send, or a record lost),
    // what Firefly III already has is found by its external ids, so
    // nothing is made twice.
    final there = sent.isEmpty
        ? await client.findByExternalPrefix(fireflyExternalPrefix(space.id))
        : const <String, String>{};

    var sentCount = 0;
    var deleted = 0;
    var refused = 0;
    var done = 0;
    while (true) {
      final rows = await store.due(_clock(), limit: batch);
      if (rows.isEmpty) break;
      for (final row in rows) {
        try {
          if (await _sendRow(space, store, snapshot, row, there)) {
            row.action == 'delete' ? deleted++ : sentCount++;
          }
          await store.done(row);
        } on FireflyRejected catch (e) {
          refused++;
          await store.refuse(row, e.message);
        } on FireflyServerError catch (e) {
          final wait = Duration(
            minutes: min(360, pow(2, row.attempts).toInt()),
          );
          await store.backOff(row, e.message, _clock().add(wait));
        }
      }
      done += rows.length;
      if (done % batch == 0 && pause > Duration.zero) {
        await Future<void>.delayed(pause);
      }
    }
    return FireflySpaceReport(
      sent: sentCount,
      deleted: deleted,
      refused: refused,
      waiting: await store.waitingCount(),
    );
  }

  /// The check by hash: queues each transaction whose parts are not what
  /// was last sent, and a delete for each one sent that is gone or now
  /// before Send from. It catches what no single change wrote: a payee
  /// renamed, a category changed on many transactions, the journal reading
  /// a balance differently.
  Future<void> _queueDifferences(
    FireflySpaceStore store,
    FireflySpaceSnapshot snapshot,
    Map<int, FireflySentRow> sent,
  ) async {
    final waiting = {
      for (final row in await store.db.select(store.db.fireflyOutbox).get())
        row.transactionId: row,
    };
    final now = _clock();
    for (final MapEntry(key: id, value: parts) in snapshot.parts.entries) {
      final was = sent[id];
      if (waiting.containsKey(id)) continue;
      if (was == null) {
        if (parts.isNotEmpty) await store.queue(id, at: now);
      } else if (!was.removedThere && was.hash != fireflyPartsHash(parts)) {
        await store.queue(id, at: now);
      }
    }
    for (final id in sent.keys) {
      if (snapshot.parts.containsKey(id)) continue;
      if (waiting[id]?.action == 'delete') continue;
      await store.queue(id, delete: true, at: now);
    }
  }

  /// Sends one outbox row; false when there was nothing to do.
  Future<bool> _sendRow(
    Space space,
    FireflySpaceStore store,
    FireflySpaceSnapshot snapshot,
    FireflyOutboxRow row,
    Map<String, String> there,
  ) async {
    final id = row.transactionId;
    final was = await store.sent(id);
    final parts = row.action == 'delete' ? null : snapshot.parts[id];
    if (parts == null) {
      if (was == null) return false;
      for (final group in sentGroups(was).values) {
        await client.deleteTransaction(group.id);
      }
      await store.forgetSent(id);
      return true;
    }
    if (was != null && was.removedThere) return false;
    // The money in of a matched transfer: its money out sends it.
    if (parts.isEmpty && (was == null || sentGroups(was).isEmpty)) {
      await store.recordSent(
        transactionId: id,
        externalId: was?.externalId ?? fireflyExternalId(space.id, id),
        groups: const {},
        hash: fireflyPartsHash(parts),
        at: _clock(),
      );
      return false;
    }
    final hash = fireflyPartsHash(parts);
    final externalBase = was?.externalId ?? fireflyExternalId(space.id, id);
    final before = was == null ? const <String, SentGroup>{} : sentGroups(was);
    final after = <String, SentGroup>{};
    for (final part in parts) {
      final externalId = part.suffix.isEmpty
          ? externalBase
          : '$externalBase:${part.suffix}';
      final fields = _split(
        part,
        source: await _accountId(store, snapshot, part.source),
        destination: await _accountId(store, snapshot, part.destination),
        externalId: externalId,
      );
      final old = before[part.suffix];
      if (old != null) {
        final changed = _changedFields(old.fields, fields);
        if (changed.isNotEmpty) {
          try {
            await client.updateTransaction(old.id, changed);
          } on FireflyNotFound {
            // The person deleted it in Firefly III: it stays deleted
            // unless they choose Send everything again.
            await store.recordSent(
              transactionId: id,
              externalId: externalBase,
              groups: before,
              hash: hash,
              at: _clock(),
              removedThere: true,
            );
            return false;
          }
        }
        after[part.suffix] = (id: old.id, fields: fields);
        continue;
      }
      // Made before but not recorded: a lost record, or an answer that
      // never arrived. Found by its external id, it is changed, not made
      // twice.
      var group = there[externalId];
      if (group == null && row.attempts > 0) {
        group = await client.findByExternalId(externalId);
      }
      if (group != null) {
        await client.updateTransaction(group, fields);
      } else {
        try {
          group = await client.createTransaction(fields);
        } on FireflyRejected catch (e) {
          if (!e.duplicate) rethrow;
          group = await client.findByExternalId(externalId);
          if (group == null) rethrow;
        }
      }
      after[part.suffix] = (id: group, fields: fields);
    }
    // Parts it no longer has, such as a fee taken off.
    for (final MapEntry(:key, :value) in before.entries) {
      if (!after.containsKey(key)) await client.deleteTransaction(value.id);
    }
    await store.recordSent(
      transactionId: id,
      externalId: externalBase,
      groups: after,
      hash: hash,
      at: _clock(),
    );
    return true;
  }

  /// What an edit sends: only the fields that changed since the last send,
  /// so a change one of the person's Firefly III rules made to another
  /// field stays. The kind and both accounts go together.
  static Map<String, Object?> _changedFields(
    Map<String, Object?> before,
    Map<String, Object?> now,
  ) {
    bool same(Object? a, Object? b) =>
        a is List && b is List ? a.join('\u0000') == b.join('\u0000') : a == b;
    final out = <String, Object?>{};
    for (final MapEntry(:key, :value) in now.entries) {
      if (!same(before[key], value)) out[key] = value;
    }
    for (final key in before.keys) {
      if (!now.containsKey(key)) {
        out[key] = key == 'tags' ? const <String>[] : '';
      }
    }
    if (out.containsKey('type') ||
        out.containsKey('source_id') ||
        out.containsKey('destination_id')) {
      out
        ..['type'] = now['type']
        ..['source_id'] = now['source_id']
        ..['destination_id'] = now['destination_id'];
    }
    return out;
  }

  Map<String, Object?> _split(
    FireflyPart part, {
    required String source,
    required String destination,
    required String externalId,
  }) => {
    'type': part.type.name,
    'date': fireflyDate(part.at, offset),
    'amount': fireflyAmount(part.amountMinor, minorUnitDigits(part.currency)),
    'currency_code': part.currency,
    if (part.foreignAmountMinor case final foreign?) ...{
      'foreign_amount': fireflyAmount(
        foreign,
        minorUnitDigits(part.foreignCurrency!),
      ),
      'foreign_currency_code': part.foreignCurrency,
    },
    'description': part.description,
    'source_id': source,
    'destination_id': destination,
    'category_name': ?part.category,
    'tags': part.tags,
    'notes': ?part.notes,
    'external_id': externalId,
  };

  /// [spec]'s Firefly III id: as recorded, found there by name and kind,
  /// or made. An asset or liability opens with its balance on the Send
  /// from day, changed when that changes.
  Future<String> _accountId(
    FireflySpaceStore store,
    FireflySpaceSnapshot snapshot,
    FireflyAccountSpec spec,
  ) async {
    final opening = spec.isOwn
        ? '${snapshot.openings[spec.key] ?? 0}@$_openingDate'
        : null;
    final openingMinor = spec.isOwn ? snapshot.openings[spec.key] ?? 0 : null;
    final known = await store.account(spec.key);
    if (known != null) {
      if (known.name == spec.name && known.opening == opening) {
        return known.fireflyId;
      }
      try {
        await client.updateAccount(
          known.fireflyId,
          spec,
          openingMinor: openingMinor,
          openingDate: _openingDate,
        );
        await store.recordAccount(
          key: spec.key,
          fireflyId: known.fireflyId,
          name: spec.name,
          opening: opening,
        );
        return known.fireflyId;
      } on FireflyNotFound {
        // Deleted there: made again below.
        await store.forgetAccount(spec.key);
      }
    }
    if (spec.currency case final currency? when _currencies.add(currency)) {
      await client.ensureCurrency(currency);
    }
    var id = await client.findAccount(spec.name, spec.kind);
    if (id != null) {
      if (spec.isOwn) {
        await client.updateAccount(
          id,
          spec,
          openingMinor: openingMinor,
          openingDate: _openingDate,
        );
      }
    } else {
      id = await client.createAccount(
        spec,
        openingMinor: openingMinor,
        openingDate: _openingDate,
      );
    }
    await store.recordAccount(
      key: spec.key,
      fireflyId: id,
      name: spec.name,
      opening: opening,
    );
    return id;
  }

  /// Compares each account sent from [space] with its balance in Firefly
  /// III; empty when they all agree.
  Future<List<FireflyBalanceDifference>> checkBalances(
    Space space,
    AppDatabase db,
  ) async {
    final store = FireflySpaceStore(db);
    final snapshot = await readFireflySpace(db, space: space, from: from);
    final out = <FireflyBalanceDifference>[];
    for (final account in await store.accounts()) {
      final spec = snapshot.accounts[account.key];
      if (spec == null || !spec.isOwn) continue;
      final digits = minorUnitDigits(spec.currency ?? 'KES');
      final there = await client.accountBalance(account.fireflyId, digits);
      // Firefly III shows what a liability owes as a negative balance.
      final thereValue = there == null
          ? null
          : spec.kind == FireflyAccountKind.liability
          ? -there
          : there;
      final expected = snapshot.balances[account.key] ?? 0;
      if (thereValue != expected) {
        out.add(
          FireflyBalanceDifference(
            key: account.key,
            name: spec.name,
            expectedMinor: expected,
            thereMinor: thereValue,
          ),
        );
      }
    }
    return out;
  }
}
