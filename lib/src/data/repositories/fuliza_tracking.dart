import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../database/database_providers.dart';
import 'app_settings_repository.dart';
import 'transactions_repository.dart';

/// Where the space that reads M-Pesa keeps whether to track Fuliza, as it
/// keeps "Which line was this?".
const trackFulizaKey = 'mpesa.trackFuliza';

/// Whether a space shows Fuliza. Not everyone uses Fuliza, so it shows only
/// once a Fuliza message has been read ([seen]), and the person can stop
/// tracking it ([tracked], on until they switch it off).
///
/// Hidden, nothing changes in the books: every draw, repayment and charge
/// is still posted to Fuliza owed and Fuliza charges as before, so each
/// reported balance still adds up and nothing lands in Not yet sorted. The
/// screens only leave Fuliza out: M-Pesa shows its wallet, the balance
/// M-Pesa reports, and no debt.
@immutable
class FulizaTracking {
  const FulizaTracking({required this.seen, required this.tracked});

  /// No Fuliza message read yet: nothing to show.
  static const unseen = FulizaTracking(seen: false, tracked: true);

  /// A Fuliza draw or repayment is among the space's records.
  final bool seen;

  /// The person's "Track Fuliza" switch, on by default.
  final bool tracked;

  /// Whether Fuliza shows anywhere in the space.
  bool get shown => seen && tracked;

  @override
  bool operator ==(Object other) =>
      other is FulizaTracking && other.seen == seen && other.tracked == tracked;

  @override
  int get hashCode => Object.hash(seen, tracked);
}

/// The seeded category Fuliza repayments are filed under.
const fulizaRepaymentCategoryKey = 'fuliza_repayment';

/// A Fuliza draw or repayment.
bool isFulizaKind(TransactionKind? kind) =>
    kind == TransactionKind.fulizaDraw ||
    kind == TransactionKind.fulizaRepayment;

/// Whether [db] holds a Fuliza message: a draw or a repayment, read from a
/// message or a statement, or typed in.
Future<bool> fulizaSeenIn(AppDatabase db) async {
  final row = await db
      .customSelect(
        'SELECT 1 FROM transactions WHERE kind IN (?, ?) LIMIT 1',
        variables: [
          Variable<String>(TransactionKind.fulizaDraw.name),
          Variable<String>(TransactionKind.fulizaRepayment.name),
        ],
        readsFrom: {db.transactions},
      )
      .getSingleOrNull();
  return row != null;
}

/// The "Track Fuliza" switch as saved in [settings]: on unless switched off.
Future<bool> fulizaTrackedIn(AppSettingsRepository settings) async =>
    (await settings.readJson(trackFulizaKey))?['track'] != false;

/// [db]'s space's Fuliza tracking, for a space that need not be open, such
/// as one Firefly III is sent from.
Future<FulizaTracking> readFulizaTracking(AppDatabase db) async =>
    FulizaTracking(
      seen: await fulizaSeenIn(db),
      tracked: await fulizaTrackedIn(DriftAppSettingsRepository(db)),
    );

/// The open space's Fuliza tracking, following its records and the switch.
class FulizaTrackingController extends AsyncNotifier<FulizaTracking> {
  @override
  Future<FulizaTracking> build() async {
    ref.watch(ledgerChangesProvider);
    return FulizaTracking(
      seen: await fulizaSeenIn(ref.watch(appDatabaseProvider)),
      tracked: await fulizaTrackedIn(ref.watch(appSettingsRepositoryProvider)),
    );
  }

  /// The "Track Fuliza" switch. Off hides Fuliza; on shows it again, with
  /// everything kept in the meantime.
  Future<void> setTracked(bool track) async {
    await ref.read(appSettingsRepositoryProvider).writeJson(trackFulizaKey, {
      'track': track,
    });
    ref.invalidateSelf();
    await future;
  }
}

final fulizaTrackingProvider =
    AsyncNotifierProvider<FulizaTrackingController, FulizaTracking>(
      FulizaTrackingController.new,
    );

/// Whether the open space shows Fuliza; false until it is known.
Future<bool> fulizaShown(Ref ref) async =>
    (await ref.watch(fulizaTrackingProvider.future)).shown;
