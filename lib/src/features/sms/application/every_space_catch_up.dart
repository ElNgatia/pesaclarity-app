import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/database/database_providers.dart';
import '../../../data/database/space_databases.dart';
import '../../../data/repositories/accounts_repository.dart';
import '../../../data/repositories/app_settings_repository.dart';
import '../../../data/repositories/balances_repository.dart';
import '../../../data/repositories/institutions_repository.dart';
import '../../../data/repositories/message_reads_repository.dart';
import '../../../data/repositories/review_inbox_repository.dart';
import '../../../data/repositories/sms_scan_marks_repository.dart';
import '../../../data/repositories/transactions_repository.dart';
import '../../../domain/spaces/space.dart';
import '../../accounts/application/mpesa_lines_providers.dart';
import '../../accounts/domain/institution.dart';
import '../../spaces/application/routing_providers.dart';
import '../data/sms_source.dart';
import '../domain/scan_range.dart';
import 'scan_range_provider.dart';
import 'sms_capture_providers.dart';
import 'sms_ingestor.dart';
import 'sms_scan_service.dart';

/// Lets one catch-up run at a time, whichever space it reads into, so a
/// capture that starts afresh (another space opened) never reads into a
/// space while the last one still does.
class CatchUpTurns {
  Future<void> _last = Future.value();

  /// Runs [work] once every catch-up before it is done.
  Future<T> run<T>(Future<T> Function() work) {
    final turn = _last.then((_) => work());
    _last = turn.then((_) {}, onError: (_) {});
    return turn;
  }
}

final catchUpTurnsProvider = Provider<CatchUpTurns>((ref) => CatchUpTurns());

/// The accounts each space reads, by its switched-on ids, each id given to
/// the first space in [order] that has it on: one reader per account,
/// whatever an older choice or a restored copy left switched on. An M-Pesa
/// line (`mpesa#<id>`) is an account of its own.
Map<String, Set<String>> readersByAccount(List<(String, Set<String>)> order) {
  final claimed = <String>{};
  return {
    for (final (spaceId, ids) in order)
      spaceId: {
        for (final id in ids)
          if (claimed.add(id)) id,
      },
  };
}

/// Reads what arrived since their last scan for the accounts of every space
/// on the list but the open one, each message into the database of the
/// space that reads its account, as that space's own catch-up would when
/// it opens. [readHere] are the ids the open space has switched on: those
/// accounts are its own to read.
///
/// Each space's database is opened only while it is read, and closed
/// afterwards. A space that cannot be read is skipped, so reading never
/// stops for it. [stillWanted] is asked before each space: when it says no
/// (another space opened), the rest is left to the next catch-up.
///
/// In each space the same rules hold as when it is open: one message is
/// stored in one space only (`heldElsewhere`), its M-Pesa line decides
/// where it is read, own transfers pair as it is stored (decision 0030),
/// and Personal's shared lines are sorted by the owner's rules (decision
/// 0027). The iPhone's queue lets go of an M-Pesa message only once every
/// space reading one of its lines has read it.
///
/// Returns what each space that read anything added, by space id.
Future<Map<String, SmsIngestSummary>> catchUpEverySpace(
  Ref ref, {
  required Set<String> readHere,
  bool Function()? stillWanted,
}) async {
  final spaces = ref.read(spaceDatabasesProvider);
  final open = ref.read(activeSpaceIdProvider);
  final listed = await spaces.listed();
  final others = [
    for (final space in listed)
      if (space.id != open) space,
  ];
  if (others.isEmpty) return const {};
  final ids = {for (final space in listed) space.id};
  final catalogue = ref.read(institutionCatalogueProvider);
  final source = ref.read(smsSourceProvider);
  final parse = ref.read(smsParseBatchProvider);
  final clock = ref.read(clockProvider);
  final lines = ref.read(mpesaLinesProvider.notifier);
  final router = ref.read(sharedLineRouterProvider);

  // The open space first, then Personal, as when a business opens and
  // leaves to Personal what both have on.
  final order = <(String, Set<String>)>[(open, readHere)];
  final results = <String, SmsIngestSummary>{};
  for (final space in others) {
    if (stillWanted != null && !stillWanted()) break;
    try {
      final (db, close) = await spaces.open(space.id);
      try {
        order.add((
          space.id,
          await DriftInstitutionsRepository(db).selectedIds(),
        ));
        final selected = institutionsReadWith(
          catalogue,
          readersByAccount(order)[space.id]!,
        );
        if (selected.isEmpty) continue;
        final ingestor = SmsIngestor(
          accounts: DriftAccountsRepository(db),
          transactions: DriftTransactionsRepository(db),
          reviewInbox: DriftReviewInboxRepository(db),
          reads: MessageReadsRepository(db),
          parse: parse,
          lines: SpaceMessageLines(
            spaceId: space.id,
            controller: () => lines,
            listed: () async => ids,
            asks: () => readsMpesa(db),
          ),
          moveToAccount: DriftBalancesRepository(db).moveToAccount,
          heldElsewhere: (hashes) => spaces.heldOutside(space.id, hashes),
        );
        final scan = SmsScanService(
          source: source,
          ingestor: ingestor,
          marks: DriftSmsScanMarksRepository(db),
          releaseUntil: queueReleaseFor(
            source,
            space.id,
            lines: () => lines,
            listed: () async => ids,
          ),
        );
        final range = ScanRange.fromJson(
          await DriftAppSettingsRepository(db)
              .readJson(ScanRangeController.settingsKey),
        );
        final summary = await catchUpOnInbox(
          scan,
          selected,
          range: range,
          now: clock(),
        );
        results[space.id] = summary;
        // Payments on lines Personal shares with a business, sorted by what
        // the owner taught the app, as when Personal is open.
        if (summary.added > 0 && space.id == personalSpaceId) {
          await router.applyRules();
        }
      } finally {
        if (close) await db.close();
      }
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Reading for ${space.id} failed: $error');
    }
  }
  return results;
}
