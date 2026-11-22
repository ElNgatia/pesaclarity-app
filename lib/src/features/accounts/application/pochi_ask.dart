import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ujumbe/ujumbe.dart';

import '../../../data/database/app_database.dart';
import '../../../data/database/database_providers.dart';
import '../../../data/repositories/accounts_repository.dart';
import '../../../data/repositories/app_settings_repository.dart';
import '../../../domain/accounts/mpesa_family.dart';
import '../../sms/application/sms_capture_providers.dart';
import '../../sms/application/sms_ingestor.dart';
import '../domain/institution.dart';
import 'mpesa_lines_providers.dart' show mpesaInstitution;

/// What waits of the person's Pochi la Biashara in the open space: the
/// messages into it read before it was added (decision 0026 item 5).
class PochiWaiting {
  const PochiWaiting({
    required this.payments,
    required this.firstAt,
    required this.declined,
  });

  /// How many messages wait.
  final int payments;

  /// When the first arrived: the account opens then.
  final DateTime firstAt;

  /// Whether the person answered "Not now", so it is not asked again and
  /// is offered in Add or remove accounts instead.
  final bool declined;
}

/// "You have Pochi la Biashara. Add it?" in the space that read its
/// messages. Pochi belongs to that space (decision 0026 item 5): it is
/// asked, added and remembered there.
class PochiAsk {
  PochiAsk(this._db, {required this.ingestor, required this.mpesa});

  final AppDatabase _db;

  /// Reads the waiting messages onto the account on Add.
  final SmsIngestor ingestor;

  /// M-Pesa, whose messages Pochi's are.
  final Institution mpesa;

  Future<List<ReviewItem>> _items() =>
      (_db.select(_db.reviewItems)
            ..where(
              (r) =>
                  r.reason.equals(pochiAskReason) &
                  r.resolvedAt.isNull() &
                  r.body.isNotNull(),
            )
            ..orderBy([(r) => OrderingTerm.asc(r.receivedAt)]))
          .get();

  /// What waits; null when nothing does, as once Pochi is added.
  Future<PochiWaiting?> waiting() async {
    final items = await _items();
    if (items.isEmpty) return null;
    final declined =
        (await DriftAppSettingsRepository(_db)
            .readJson(pochiDeclinedKey))?['declined'] ==
        true;
    return PochiWaiting(
      payments: items.length,
      firstAt: items.first.receivedAt,
      declined: declined,
    );
  }

  /// Add: Pochi la Biashara becomes an account under the first M-Pesa
  /// wallet, and every message that waited is read onto it. Returns how
  /// many were.
  Future<int> add() async {
    final items = await _items();
    final first = items.firstOrNull?.receivedAt ?? DateTime.now().toUtc();
    await DriftAccountsRepository(_db).accountForInstitution(
      mpesa.id,
      name: pochiName,
      type: AccountType.other,
      openingDate: first,
      currency: mpesa.pack.currency,
      reference: pochiReference,
    );
    await DriftAppSettingsRepository(_db)
        .writeJson(pochiDeclinedKey, {'declined': false});
    if (items.isEmpty) return 0;
    final read = await ingestor.ingest(
      [
        for (final item in items)
          SmsMessage(
            sender: item.sender,
            body: item.body!,
            receivedAt: item.receivedAt,
          ),
      ],
      [mpesa],
    );
    return read.added;
  }

  /// "Not now": not asked again in this space. The messages keep waiting,
  /// never income, spending or M-Pesa's money, so adding it later from Add
  /// or remove accounts still reads them.
  Future<void> decline() =>
      DriftAppSettingsRepository(_db)
          .writeJson(pochiDeclinedKey, {'declined': true});
}

final pochiAskProvider = Provider<PochiAsk>(
  (ref) => PochiAsk(
    ref.watch(appDatabaseProvider),
    ingestor: ref.watch(smsIngestorProvider),
    mpesa: mpesaInstitution(ref),
  ),
);

/// What waits of Pochi la Biashara in the open space, following the review
/// inbox and the answer; null when nothing does.
final pochiWaitingProvider = StreamProvider<PochiWaiting?>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final ask = ref.watch(pochiAskProvider);
  return db
      .tableUpdates(
        TableUpdateQuery.onAllTables([db.reviewItems, db.appSettings]),
      )
      .asyncMap((_) => ask.waiting())
      .startWith(ask.waiting());
});

extension<T> on Stream<T> {
  /// This stream, after [first]'s value.
  Stream<T> startWith(Future<T> first) async* {
    yield await first;
    yield* this;
  }
}
