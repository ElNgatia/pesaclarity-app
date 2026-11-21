import 'dart:isolate';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:ujumbe/ujumbe.dart';

import '../../../data/database/app_database.dart'
    show TransactionRecord, TransactionsCompanion;
import '../../../data/repositories/accounts_repository.dart';
import '../../../data/repositories/message_reads_repository.dart';
import '../../../data/repositories/reader_templates_repository.dart';
import '../../../data/repositories/review_inbox_repository.dart';
import '../../../data/repositories/transactions_repository.dart';
import '../../../domain/accounts/mpesa_lines.dart';
import '../../../domain/reader/reading_template.dart';
import '../../accounts/domain/institution.dart';
import '../../review/application/review_draft.dart';
import '../data/sms_source.dart';
import 'transaction_mapping.dart';

/// Where this space reads one M-Pesa message, by its line.
sealed class LineRead {
  const LineRead();
}

/// On the account keyed by [reference]: a line's (see [lineReference]), or
/// null for the one M-Pesa account every line is read into before a split.
final class ReadOnAccount extends LineRead {
  const ReadOnAccount(this.reference);

  final String? reference;
}

/// On a line another space reads, or a SIM waiting on a question: not here.
final class ReadElsewhere extends LineRead {
  const ReadElsewhere();
}

/// Its line cannot be told: it waits for "Which line was this?".
final class AskLine extends LineRead {
  const AskLine();
}

/// Tells which M-Pesa line each message is on and where it is read (see
/// `MpesaLines`).
abstract interface class MessageLines {
  /// One answer for each of [facts], in order; they come oldest first.
  Future<List<LineRead>> place(List<LineFacts> facts);
}

/// What [parsed], from [message], says about its line.
LineFacts lineFactsOf(ParsedTransaction parsed, SmsMessage message) =>
    LineFacts(
      hash: parsed.rawHash,
      at: parsed.time,
      sim: lineOf(message),
      amountMinor: parsed.amountMinor,
      feeMinor: parsed.feeMinor ?? 0,
      inflow: parsed.direction == Direction.incoming,
      balanceMinor: parsed.balanceMinor,
    );

/// Parses [messages] with [packs]; one result per message, in order.
typedef SmsParseBatch = Future<List<ParseResult>> Function(
  List<ParserPack> packs,
  List<SmsMessage> messages,
);

/// Parses on a background isolate so a large scan never blocks the UI.
Future<List<ParseResult>> parseInBackground(
  List<ParserPack> packs,
  List<SmsMessage> messages,
) => Isolate.run(() => parseAll(packs, messages));

/// Parses on the calling isolate.
List<ParseResult> parseAll(List<ParserPack> packs, List<SmsMessage> messages) {
  final parser = SmsParser(packs);
  return [for (final message in messages) parser.parse(message)];
}

/// What one batch of messages turned into.
@immutable
class SmsIngestSummary {
  const SmsIngestSummary({
    this.added = 0,
    this.duplicates = 0,
    this.forReview = 0,
    this.ignored = 0,
    this.updated = 0,
    this.changes = const [],
  });

  /// New transactions stored.
  final int added;

  /// Transactions already in the ledger, such as from an earlier scan.
  final int duplicates;

  /// Messages from selected senders that no rule matched, newly in review.
  final int forReview;

  /// Messages from senders that are not selected, dropped unstored.
  final int ignored;

  /// Transactions the readers now read better, when reading again (see
  /// [SmsIngestor.ingest]).
  final int updated;

  /// Where the transactions added or updated while reading again are.
  final List<ReadChange> changes;

  SmsIngestSummary operator +(SmsIngestSummary other) => SmsIngestSummary(
    added: added + other.added,
    duplicates: duplicates + other.duplicates,
    forReview: forReview + other.forReview,
    ignored: ignored + other.ignored,
    updated: updated + other.updated,
    changes: [...changes, ...other.changes],
  );

  @override
  bool operator ==(Object other) =>
      other is SmsIngestSummary &&
      other.added == added &&
      other.duplicates == duplicates &&
      other.forReview == forReview &&
      other.ignored == ignored &&
      other.updated == updated;

  @override
  int get hashCode =>
      Object.hash(added, duplicates, forReview, ignored, updated);

  @override
  String toString() =>
      'SmsIngestSummary(added: $added, duplicates: $duplicates, '
      'forReview: $forReview, ignored: $ignored, updated: $updated)';
}

/// A transaction added or updated by reading messages again: its
/// institution, account and time.
@immutable
class ReadChange {
  const ReadChange(this.institutionId, this.accountId, this.at);

  final String institutionId;
  final int accountId;
  final DateTime at;
}

/// The readers that read [parsed], as kept on its transaction: the engine
/// and pack versions, such as `0.3.0 mpesa@0.3.1`.
String readByOf(ParsedTransaction parsed) =>
    '$engineVersion ${parsed.packId}@${parsed.packVersion}';

/// Whether [fresh] reads any field of [row] differently. Its account and
/// currency are left to `MessageRecheck`.
bool readsDifferently(TransactionRecord row, TransactionsCompanion fresh) =>
    !row.occurredAt.isAtSameMomentAs(fresh.occurredAt.value) ||
    row.amountMinor != fresh.amountMinor.value ||
    row.direction != fresh.direction.value ||
    row.kind != fresh.kind.value ||
    row.feeMinor != fresh.feeMinor.value ||
    row.counterpartyKind != fresh.counterpartyKind.value ||
    row.counterpartyValue != fresh.counterpartyValue.value ||
    row.counterpartyName != fresh.counterpartyName.value ||
    row.receiptNo != fresh.receiptNo.value ||
    row.linkedReceiptNo != fresh.linkedReceiptNo.value ||
    row.dedupeKey != fresh.dedupeKey.value ||
    row.balanceAfterMinor != fresh.balanceAfterMinor.value ||
    row.owedAfterMinor != fresh.owedAfterMinor.value ||
    !_sameMoment(row.owedDueAt, fresh.owedDueAt.value);

bool _sameMoment(DateTime? a, DateTime? b) =>
    a == null || b == null ? a == b : a.isAtSameMomentAs(b);

/// Turns messages into ledger transactions and review items.
///
/// Parsed messages keep only their fields and hash. Unmatched messages from
/// selected senders go to the review inbox, the one place their text is
/// kept. Messages from any other sender are dropped.
/// The first template [message] fits, read into a complete draft, or null.
ReviewDraft? _readWith(List<ReadingTemplate> templates, String message) {
  for (final template in templates) {
    final reading = template.read(message);
    if (reading == null) continue;
    final draft = ReviewDraft.fromReading(reading);
    if (draft.isComplete) return draft;
  }
  return null;
}

class SmsIngestor {
  SmsIngestor({
    required this._accounts,
    required this._transactions,
    required this._reviewInbox,
    this._templates,
    this._reads,
    this._parse = parseInBackground,
    this._lines,
    this._moveToAccount,
    this._heldElsewhere,
    List<Institution>? catalogue,
  }) : _catalogue = catalogue ?? institutionCatalogue;

  final AccountsRepository _accounts;
  final TransactionsRepository _transactions;
  final ReviewInboxRepository _reviewInbox;

  /// Layouts the person asked to be read the same way; a message that fits
  /// one skips the review inbox.
  final ReaderTemplatesRepository? _templates;

  /// What is already known about each message; without it only dedupe keys
  /// keep a message from being stored twice.
  final MessageReadsRepository? _reads;
  final SmsParseBatch _parse;

  /// The M-Pesa lines on this phone; without it every M-Pesa message is
  /// read into one account, as before lines were told apart.
  final MessageLines? _lines;

  /// Moves a stored transaction to another account of this space, for a
  /// message read again into the line it was on.
  final Future<void> Function(int transactionId, int accountId)? _moveToAccount;

  /// Which of the given message hashes another space already holds. Each
  /// message lands in one space: one another space holds (it read it while
  /// it read the account, or the person moved it there) is never stored
  /// here as well, whichever space reads the account now.
  final Future<Set<String>> Function(Set<String> hashes)? _heldElsewhere;

  /// Every institution the app knows, for messages one institution sends
  /// about money on another's account (see
  /// [ParsedTransaction.institution]).
  final List<Institution> _catalogue;

  /// Ingests [messages], reading only those from the [selected] institutions.
  ///
  /// A message is stored once: one that already has a transaction, or that
  /// the person set aside or dealt with in review, adds nothing. One left
  /// waiting in review that the readers now read is added and leaves review.
  ///
  /// With [again], as when messages are read again with newer readers, a
  /// transaction the readers now read differently is updated, unless the
  /// person touched it (see [MessageReadsRepository.stored]): its time,
  /// amount, direction, kind, fee, other party, receipt, and the balance or
  /// amount owed after it. Its account, currency and everything the person
  /// set stay.
  Future<SmsIngestSummary> ingest(
    List<SmsMessage> messages,
    List<Institution> selected, {
    bool again = false,
  }) async {
    if (messages.isEmpty) return const SmsIngestSummary();
    if (selected.isEmpty) return SmsIngestSummary(ignored: messages.length);

    final results = await _parse([
      for (final institution in selected) institution.pack,
    ], messages);

    final hashes = {
      for (final result in results)
        if (result
            case ParsedTransaction(:final rawHash) ||
                Unmatched(:final rawHash) ||
                KnownNotice(:final rawHash))
          rawHash,
    };
    final reads = _reads;
    final known = reads == null
        ? const <String, StoredReading>{}
        : await reads.stored(hashes);
    final inReview = reads == null
        ? const <String, (int, bool)>{}
        : await reads.reviewItems(hashes);
    final setAside = reads == null
        ? const <String>{}
        : await reads.setAside(hashes);
    final heldElsewhere = _heldElsewhere;
    final elsewhere = heldElsewhere == null
        ? const <String>{}
        : await heldElsewhere({
            for (final hash in hashes)
              if (!known.containsKey(hash) && !setAside.contains(hash)) hash,
          });
    // Stored before, set aside, dealt with in review, or in another space.
    bool settled(String hash) =>
        known.containsKey(hash) ||
        setAside.contains(hash) ||
        elsewhere.contains(hash) ||
        (inReview[hash]?.$2 ?? false);
    final leavingReview = <int>[];
    void leaveReview(String hash) {
      final item = inReview[hash];
      if (item != null) leavingReview.add(item.$1);
    }

    // A message can be about money on another institution's account, such
    // as KCB confirming an M-Pesa payment: it goes on that account even when
    // that institution's own messages are not read.
    final institutions = {
      for (final i in _catalogue) i.id: i,
      for (final i in selected) i.id: i,
    };
    // An institution this app does not know keeps the message on the
    // sender's own account.
    String accountOn(ParsedTransaction p) =>
        institutions.containsKey(p.accountInstitution)
        ? p.accountInstitution
        : p.packId;

    // Each M-Pesa message's line, oldest first, so a balance carries on.
    // One stored already is placed again only when read again, when it may
    // move to the line it was on.
    final lineReads = <int, LineRead>{};
    final lines = _lines;
    if (lines != null) {
      final order = <int>[];
      final facts = <LineFacts>[];
      for (final (i, result) in results.indexed) {
        if (result is! ParsedTransaction ||
            accountOn(result) != mpesaInstitutionId ||
            (!again && settled(result.rawHash))) {
          continue;
        }
        order.add(i);
        facts.add(lineFactsOf(result, messages[i]));
      }
      if (facts.isNotEmpty) {
        final placed = await lines.place(facts);
        for (final (k, i) in order.indexed) {
          lineReads[i] = placed[k];
        }
      }
    }
    // The line account of each message read onto one.
    final lineReferences = <String, String?>{};
    // Stored transactions read again onto a line, to move there.
    final moves = <(StoredReading, String, ParsedTransaction)>[];

    final parsedByPack = <String, List<ParsedTransaction>>{};
    final readByPack = <String, List<(ReviewDraft, SmsMessage, String)>>{};
    final templates = <String, List<ReadingTemplate>>{};
    var forReview = 0;
    var ignored = 0;
    var settledCount = 0;
    var updated = 0;
    final changes = <ReadChange>[];
    for (final (i, result) in results.indexed) {
      switch (result) {
        case ParsedTransaction(:final rawHash):
          final line = lineReads[i];
          if (settled(rawHash)) {
            settledCount++;
            final row = known[rawHash];
            if (again && row != null && reads != null) {
              if (await _readAgain(reads, row, result)) {
                updated++;
                changes.add(
                  ReadChange(
                    result.accountInstitution,
                    row.record.accountId,
                    result.time,
                  ),
                );
              }
              if (line case ReadOnAccount(:final reference?)) {
                moves.add((row, reference, result));
              }
            }
            continue;
          }
          switch (line) {
            case ReadElsewhere():
              ignored++;
              continue;
            case AskLine():
              // Kept as a message, the one place its text is, until the
              // person says which line it was on.
              final message = messages[i];
              if (await _reviewInbox.addIfNew(
                institutionId: result.packId,
                sender: message.sender,
                receivedAt: message.receivedAt,
                messageHash: rawHash,
                body: message.body,
                reason: whichLineReason,
              )) {
                forReview++;
              }
              continue;
            case ReadOnAccount(:final reference):
              lineReferences[rawHash] = reference;
            case null:
          }
          leaveReview(rawHash);
          (parsedByPack[result.packId] ??= []).add(result);
        case Unmatched(:final message, :final rawHash):
          if (known.containsKey(rawHash) ||
              setAside.contains(rawHash) ||
              elsewhere.contains(rawHash)) {
            settledCount++;
            continue;
          }
          final layouts = _templates == null
              ? const <ReadingTemplate>[]
              : templates[result.packId] ??= await _templates.forInstitution(
                  result.packId,
                );
          final draft = (inReview[rawHash]?.$2 ?? false)
              ? null
              : _readWith(layouts, message.body);
          if (draft != null) {
            leaveReview(rawHash);
            (readByPack[result.packId] ??= []).add((draft, message, rawHash));
            continue;
          }
          final added = await _reviewInbox.addIfNew(
            institutionId: result.packId,
            sender: message.sender,
            receivedAt: message.receivedAt,
            messageHash: rawHash,
            body: message.body,
            reason: result.reason,
          );
          if (added) forReview++;
        case KnownNotice(:final rawHash):
          // Known not to be a transaction, such as a declined card payment.
          // An older pack may have queued it for review: take it out.
          leaveReview(rawHash);
          ignored++;
        case Ignored():
          ignored++;
      }
    }

    var added = 0;
    var parsedCount = 0;

    // Each account gets the messages that show its number and currency,
    // oldest first so an account from before numbers were read takes the
    // first number it sees.
    final pending = <(String, String?, String), List<Object>>{};
    final firstSeen = <(String, String?, String), DateTime>{};
    void note((String, String?, String) key, DateTime when, Object item) {
      (pending[key] ??= []).add(item);
      final seen = firstSeen[key];
      if (seen == null || when.isBefore(seen)) firstSeen[key] = when;
    }

    for (final MapEntry(key: packId, value: read) in readByPack.entries) {
      final institution = institutions[packId]!;
      for (final (draft, message, hash) in read) {
        final currency = draft.currency ?? institution.pack.currency;
        note(
          (packId, null, currency),
          draft.occurredAt(message.receivedAt),
          (draft, message, hash),
        );
      }
    }
    for (final parsed in parsedByPack.values) {
      for (final p in parsed) {
        final on = accountOn(p);
        // A message that names no account of its own, such as a card
        // payment abroad, is on the account in the institution's own
        // currency, though its amount is in another.
        final currency = p.ownAccount == null
            ? institutions[on]!.pack.currency
            : p.currency;
        // An M-Pesa line's message is on that line's account.
        final reference = lineReferences.containsKey(p.rawHash)
            ? lineReferences[p.rawHash]
            : p.ownAccount;
        note((on, reference, currency), p.time, p);
      }
    }
    final keys = pending.keys.toList()
      ..sort((a, b) => firstSeen[a]!.compareTo(firstSeen[b]!));
    for (final key in keys) {
      final (packId, reference, currency) = key;
      final institution = institutions[packId]!;
      final accountId = await _accounts.accountForInstitution(
        institution.id,
        name: institution.name,
        type: institution.type,
        openingDate: firstSeen[key]!,
        currency: currency,
        reference: reference,
      );
      final rows = [
        for (final item in pending[key]!)
          switch (item) {
            ParsedTransaction() => transactionFromParsed(
              item,
              accountId: accountId,
            ).copyWith(readBy: Value(readByOf(item))),
            (
              final ReviewDraft draft,
              final SmsMessage message,
              final String hash,
            ) =>
              draft.toTransaction(
                accountId: accountId,
                receivedAt: message.receivedAt,
                messageHash: hash,
                currency: currency,
              ),
            _ => throw StateError('unexpected $item'),
          },
      ];
      final stored = await _transactions.addNew(rows);
      added += stored;
      parsedCount += rows.length;
      if (again && stored > 0 && reads != null) {
        final now = await reads.stored({
          for (final row in rows) ?row.messageHash.value,
        });
        for (final row in now.values) {
          changes.add(ReadChange(packId, accountId, row.record.occurredAt));
        }
      }
    }
    // Read again onto the line it was on: the same transaction, moved, so
    // nothing is stored twice and what the person set stays.
    final move = _moveToAccount;
    if (move != null) {
      for (final (stored, reference, p) in moves) {
        final row = stored.record;
        final institution = institutions[mpesaInstitutionId]!;
        final accountId = await _accounts.accountForInstitution(
          institution.id,
          name: institution.name,
          type: institution.type,
          openingDate: p.time,
          currency: row.currency,
          reference: reference,
        );
        if (accountId == row.accountId) continue;
        await move(row.id, accountId);
        updated++;
        changes.add(ReadChange(institution.id, accountId, row.occurredAt));
      }
    }
    for (final id in leavingReview) {
      await _reviewInbox.resolve(id);
    }

    return SmsIngestSummary(
      added: added,
      duplicates: parsedCount - added + settledCount,
      forReview: forReview,
      ignored: ignored,
      updated: updated,
      changes: changes,
    );
  }

  /// Updates [stored] from [parsed] when the person has not touched it and
  /// the readers now read it differently. Returns whether it changed.
  Future<bool> _readAgain(
    MessageReadsRepository reads,
    StoredReading stored,
    ParsedTransaction parsed,
  ) async {
    final row = stored.record;
    if (stored.touched || row.currency != parsed.currency) return false;
    final fresh = transactionFromParsed(parsed, accountId: row.accountId);
    final readBy = readByOf(parsed);
    if (!readsDifferently(row, fresh)) {
      if (row.readBy != readBy) await reads.stamp(row.id, readBy);
      return false;
    }
    return reads.update(row, fresh, readBy: readBy);
  }
}
