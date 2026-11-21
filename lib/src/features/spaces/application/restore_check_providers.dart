import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/database/database_providers.dart';
import '../../../data/database/space_databases.dart';
import '../../../data/repositories/restore_check.dart';
import '../../../data/repositories/transactions_repository.dart';
import '../../../domain/spaces/space.dart';
import 'spaces_providers.dart';

/// Payments on one side only, found after the open space was restored
/// (decision 0027, section 7).
class OneSided {
  const OneSided({
    required this.restored,
    required this.business,
    required this.payments,
    this.backupAt,
    this.lineName = 'M-Pesa',
  });

  /// The name of Personal's account the money is on: "M-Pesa".
  final String lineName;

  /// The space that was restored and is short of the other sides: the
  /// open space.
  final Space restored;

  /// The business the payments are between, with Personal.
  final Space business;
  final List<OneSidedPayment> payments;

  /// When the backup the open space was restored from was made.
  final DateTime? backupAt;

  /// Whether Personal is the space that was restored.
  bool get personalRestored => restored.kind == SpaceKind.personal;

  /// What Personal holds for the business through these: money in to it,
  /// less money out.
  int get heldMinor => payments.fold(0, (sum, p) => sum + p.signedMinor);
}

/// After the open space was restored from a backup, the payments whose
/// other side, in another space, it no longer has, if any: shown on its
/// Today or Home as "N payments on one side only" until the owner chooses.
/// Only in the space that is short. When nothing is left the check is
/// done.
final oneSidedProvider = FutureProvider<OneSided?>((ref) async {
  ref.watch(ledgerChangesProvider);
  final space = ref.watch(activeSpaceProvider);
  final db = ref.watch(appDatabaseProvider);
  final check = await RestoreCheck.read(db);
  if (check == null) return null;
  final personal = ref.watch(personalDatabaseProvider);
  Future<String> lineName(List<OneSidedPayment> payments) async =>
      (await (personal.select(personal.accounts)
                ..where((a) => a.id.equals(payments.first.lineAccountId)))
              .getSingleOrNull())
          ?.name ??
      'M-Pesa';
  final spaces = ref.read(spaceDatabasesProvider);
  List<OneSidedPayment> left(List<OneSidedPayment> all) => [
    for (final p in all)
      if (!check.apart.contains(p.link)) p,
  ];
  if (space.kind == SpaceKind.personal) {
    for (final business in await spaces.listed()) {
      if (business.id == personalSpaceId) continue;
      try {
        final (other, close) = await spaces.open(business.id);
        try {
          final missing = left(
            await missingInPersonal(personal: db, business: other),
          );
          if (missing.isNotEmpty) {
            return OneSided(
              restored: space,
              business: business,
              payments: missing,
              backupAt: check.backupAt,
              lineName: await lineName(missing),
            );
          }
        } finally {
          if (close) await other.close();
        }
      } on Object catch (error) {
        if (kDebugMode) debugPrint('Could not look in ${business.id}: $error');
      }
    }
  } else {
    final missing = left(
      await missingInBusiness(
        personal: personal,
        business: db,
        businessId: space.id,
      ),
    );
    if (missing.isNotEmpty) {
      return OneSided(
        restored: space,
        business: space,
        payments: missing,
        backupAt: check.backupAt,
        lineName: await lineName(missing),
      );
    }
  }
  await RestoreCheck.clear(db);
  return null;
});

/// The three answers on "N payments on one side only".
enum OneSidedAnswer {
  /// Make the missing sides again in the space that is short.
  makeAgain,

  /// Leave them apart: nothing changes and the card goes away.
  leaveApart,

  /// They were the owner's own (only when the business is short): they
  /// become Personal's own payments, and the business's part is undone.
  wereMine,
}

/// Carries out the owner's answer on [sided].
class OneSidedController {
  OneSidedController(this._ref);

  final Ref _ref;

  Future<void> answer(OneSided sided, OneSidedAnswer answer) async {
    final db = _ref.read(appDatabaseProvider);
    final personal = _ref.read(personalDatabaseProvider);
    switch (answer) {
      case OneSidedAnswer.leaveApart:
        final check = await RestoreCheck.read(db) ?? const RestoreCheck();
        await RestoreCheck(
          backupAt: check.backupAt,
          apart: {...check.apart, for (final p in sided.payments) p.link},
        ).save(db);
      case OneSidedAnswer.makeAgain when sided.personalRestored:
        await remakeInPersonal(
          personal: personal,
          businessId: sided.business.id,
          businessName: sided.business.name,
          payments: sided.payments,
        );
      case OneSidedAnswer.makeAgain:
        await remakeInBusiness(
          personal: personal,
          business: db,
          payments: sided.payments,
        );
      case OneSidedAnswer.wereMine:
        if (sided.personalRestored) return;
        await wereMine(
          personal: personal,
          businessId: sided.business.id,
          payments: sided.payments,
        );
    }
    _ref.invalidate(oneSidedProvider);
  }
}

final oneSidedControllerProvider = Provider<OneSidedController>(
  OneSidedController.new,
);
