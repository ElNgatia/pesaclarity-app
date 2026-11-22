import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ujumbe/ujumbe.dart';

import '../../../core/time/clock.dart';
import '../../../data/database/app_database.dart';
import '../../../data/database/database_providers.dart';
import '../../../data/database/space_databases.dart';
import '../../../data/repositories/message_reads_repository.dart';
import '../../accounts/domain/institution.dart';
import '../../categoriser/application/auto_categoriser.dart';
import '../../categoriser/application/categoriser_providers.dart';
import '../domain/pasted_messages.dart';
import 'sms_capture_providers.dart';
import 'sms_ingestor.dart';
import 'transaction_mapping.dart';

/// One payment read from pasted text.
@immutable
class PastedPayment {
  const PastedPayment({
    required this.parsed,
    required this.message,
    required this.alreadyIn,
  });

  final ParsedTransaction parsed;

  /// The pasted text as the message it was, from the sender that reads it.
  final SmsMessage message;

  /// Whether the records already hold it: the same message passed on by
  /// Shortcuts or pasted before, or the same payment from a statement.
  final bool alreadyIn;

  /// The amount in the currency's minor units.
  int get amountMinor => inCurrencyMinor(parsed.amountMinor, parsed.currency);
}

/// What one paste was found to hold, before anything is added.
@immutable
class PasteReading {
  const PasteReading({required this.payments, required this.notPayments});

  /// Every payment found, newest first.
  final List<PastedPayment> payments;

  /// Pasted messages that are not payments, or that no reader knows: left
  /// out, and not kept anywhere.
  final int notPayments;

  int get alreadyIn => payments.where((p) => p.alreadyIn).length;

  int get newCount => payments.length - alreadyIn;
}

/// What adding a paste did.
@immutable
class PasteAdded {
  const PasteAdded({required this.summary, this.newestBalance});

  final SmsIngestSummary summary;

  /// The newest pasted message's account balance, when that message prints
  /// one: what the account should now show.
  final ({String institutionId, int balanceMinor, String currency})?
  newestBalance;
}

/// Reads pasted messages on the phone and adds the new ones through the same
/// ingest Shortcuts' messages go through: the same readers, line placement,
/// one-space-per-message check and dedupe, so a pasted message and one
/// passed on by Shortcuts are one transaction. Nothing but what the readers
/// take out of a payment is stored; the pasted text is not kept.
class PasteReader {
  PasteReader({
    required this.parse,
    required this.ingestor,
    required this.now,
    this.reads,
    this.heldElsewhere,
    this.storedKeys,
  });

  final SmsParseBatch parse;
  final SmsIngestor ingestor;
  final DateTime Function() now;
  final MessageReadsRepository? reads;
  final Future<Set<String>> Function(Set<String> hashes)? heldElsewhere;

  /// Which of the given dedupe keys the records already hold, such as a
  /// payment imported from a statement.
  final Future<Set<String>> Function(Set<String> keys)? storedKeys;

  /// Finds the payments in [text], read with the [selected] institutions'
  /// readers. A pasted message has no sender, so each is tried as a message
  /// from each institution; the first that reads it as a payment keeps it.
  Future<PasteReading> read(String text, List<Institution> selected) async {
    final bodies = splitPastedMessages(text);
    if (bodies.isEmpty || selected.isEmpty) {
      return PasteReading(payments: const [], notPayments: bodies.length);
    }
    final at = now();
    final tries = [
      for (final body in bodies)
        for (final institution in selected)
          if (institution.senderIds.isNotEmpty)
            SmsMessage(
              sender: institution.senderIds.first,
              body: body,
              receivedAt: at,
            ),
    ];
    final results = await parse([for (final i in selected) i.pack], tries);
    final perBody = results.length ~/ bodies.length;
    final found = <(ParsedTransaction, SmsMessage)>[];
    final seen = <String>{};
    var notPayments = 0;
    for (var b = 0; b < bodies.length; b++) {
      final hit = [
        for (var k = 0; k < perBody; k++)
          if (results[b * perBody + k] case final ParsedTransaction p)
            (p, tries[b * perBody + k]),
      ].firstOrNull;
      if (hit == null) {
        notPayments++;
        continue;
      }
      final (parsed, tried) = hit;
      // The same message pasted twice is one payment.
      if (!seen.add(parsed.rawHash)) continue;
      found.add((
        parsed,
        SmsMessage(
          sender: tried.sender,
          body: tried.body,
          // Read from the message itself where it prints a time; else the
          // time of pasting stands in for when it arrived.
          receivedAt: parsed.timeFromMessage ? parsed.time : at,
        ),
      ));
    }

    final hashes = {for (final (p, _) in found) p.rawHash};
    final known = {
      ...?(await reads?.stored(hashes))?.keys,
      ...?await reads?.setAside(hashes),
      ...?await heldElsewhere?.call(hashes),
    };
    final keys =
        await storedKeys?.call({for (final (p, _) in found) p.dedupeKey}) ??
        const <String>{};
    final payments = [
      for (final (p, message) in found)
        PastedPayment(
          parsed: p,
          message: message,
          alreadyIn: known.contains(p.rawHash) || keys.contains(p.dedupeKey),
        ),
    ]..sort((a, b) => b.parsed.time.compareTo(a.parsed.time));
    return PasteReading(payments: payments, notPayments: notPayments);
  }

  /// Adds [reading]'s new payments to the records, oldest first, so each
  /// balance carries on from the one before.
  Future<PasteAdded> add(
    PasteReading reading,
    List<Institution> selected,
  ) async {
    final fresh = [
      for (final p in reading.payments.reversed)
        if (!p.alreadyIn) p,
    ];
    final summary = await ingestor.ingest([
      for (final p in fresh) p.message,
    ], selected);
    final newest = reading.payments
        .where((p) => p.parsed.balanceMinor != null)
        .firstOrNull;
    return PasteAdded(
      summary: summary,
      newestBalance: newest == null
          ? null
          : (
              institutionId: newest.parsed.accountInstitution,
              balanceMinor: inCurrencyMinor(
                newest.parsed.balanceMinor!,
                newest.parsed.currency,
              ),
              currency: newest.parsed.currency,
            ),
    );
  }
}

final pasteReaderProvider = Provider<PasteReader>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return PasteReader(
    parse: ref.watch(smsParseBatchProvider),
    ingestor: ref.watch(smsIngestorProvider),
    now: ref.watch(clockProvider),
    reads: ref.watch(messageReadsRepositoryProvider),
    heldElsewhere: ref.watch(spaceDatabasesProvider).heldElsewhere,
    storedKeys: (keys) => storedDedupeKeys(db, keys),
  );
});

/// Which of [keys] a transaction in [db] already has.
Future<Set<String>> storedDedupeKeys(AppDatabase db, Set<String> keys) async {
  if (keys.isEmpty) return const {};
  final t = db.transactions;
  final rows =
      await (db.selectOnly(t, distinct: true)
            ..addColumns([t.dedupeKey])
            ..where(t.dedupeKey.isIn(keys)))
          .get();
  return {for (final row in rows) ?row.read(t.dedupeKey)};
}

/// After a paste is added: sorts the new payments into categories, as
/// messages from Shortcuts are.
void categoriseAfterPaste(WidgetRef ref) {
  final suggester = ref.read(categorySuggesterProvider);
  if (suggester != null) {
    unawaited(ref.read(autoCategoriserProvider).autoCategorise(suggester));
  }
}
