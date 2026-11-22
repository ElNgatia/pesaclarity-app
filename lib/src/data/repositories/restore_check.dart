import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../domain/spaces/space.dart';
import '../../domain/spaces/space_categories.dart';
import '../database/app_database.dart';
import 'app_settings_repository.dart';
import 'category_seeds.dart';
import 'message_reads_repository.dart';
import 'space_move_repository.dart';

/// The restore check (decision 0027, section 7). A payment between spaces
/// has two linked sides: what the space it was switched to records on the
/// owner's account, and what the space where its account lives keeps (a
/// balance record, or for Pay yourself and Put money in on the line, a
/// payment on Held for that space). Restoring one space from an older
/// backup can leave one side missing. After a restore, the restored space
/// asks once about each side it is short of.

/// The restored space's own setting that says it was restored, from a
/// backup made when, and which links the owner chose to leave apart.
const restoreCheckKey = 'spaces.restoreCheck';

/// What kind of linked pair a one-sided payment is half of.
enum OneSidedKind {
  /// A payment switched to the business: Personal keeps a balance record.
  switched,

  /// Pay yourself on the owner's line.
  pay,

  /// Put money in on the owner's line.
  putIn,

  /// A correction of the business's part of the line.
  part,
}

/// One payment on one side only.
class OneSidedPayment {
  const OneSidedPayment({
    required this.link,
    required this.kind,
    required this.at,
    required this.amountMinor,
    required this.inflow,
    required this.currency,
    required this.lineAccountId,
    this.feeMinor = 0,
    this.code,
    this.name,
    this.categoryName,
    this.categoryKey,
  });

  /// The link both sides share.
  final String link;
  final OneSidedKind kind;
  final DateTime at;
  final int amountMinor;

  /// Whether it is money in to the business.
  final bool inflow;
  final String currency;
  final int feeMinor;

  /// Personal's account the money is on.
  final int lineAccountId;

  /// The M-Pesa code or bank reference.
  final String? code;

  /// Who with, and what it was filed under, where the side that is left
  /// knows (the business's side does; Personal's balance record does not).
  final String? name;
  final String? categoryName;
  final String? categoryKey;

  /// Money in to the business, less money out: what Personal holds for it
  /// through this payment.
  int get signedMinor => inflow ? amountMinor : -amountMinor;
}

OneSidedKind _kindOfLink(String link) => link.startsWith('pay:')
    ? OneSidedKind.pay
    : link.startsWith('putin:')
    ? OneSidedKind.putIn
    : link.startsWith('part:')
    ? OneSidedKind.part
    : OneSidedKind.switched;

/// The links of payments on Held for [businessId] in [personal] that pair
/// with a payment in the business: Pay yourself and Put money in on the
/// line, and corrections of its part. What "It is mine now" settled has no
/// other side.
bool _paired(String link) =>
    link.startsWith('pay:') ||
    link.startsWith('putin:') ||
    link.startsWith('part:');

/// What Personal holds for [businessId] that the business has no side of:
/// the business was restored from an older backup.
Future<List<OneSidedPayment>> missingInBusiness({
  required AppDatabase personal,
  required AppDatabase business,
  required String businessId,
}) async {
  final there = {
    for (final t in await (business.select(
      business.transactions,
    )..where((t) => t.linkId.isNotNull())).get())
      t.linkId!,
  };
  final out = <OneSidedPayment>[];
  for (final r in await (personal.select(
    personal.balanceRecords,
  )..where((r) => r.spaceId.equals(businessId))).get()) {
    if (there.contains(r.linkId)) continue;
    out.add(
      OneSidedPayment(
        link: r.linkId,
        kind: OneSidedKind.switched,
        at: r.occurredAt,
        amountMinor: r.amountMinor,
        inflow: r.direction == TransactionDirection.inflow,
        currency: r.currency,
        feeMinor: r.feeMinor,
        lineAccountId: r.accountId,
        code: r.receiptNo,
      ),
    );
  }
  final held = {
    for (final a
        in await (personal.select(personal.accounts)..where(
              (a) =>
                  a.type.equalsValue(AccountType.heldForSpace) &
                  a.linkedSpaceId.equals(businessId),
            ))
            .get())
      a.id: a,
  };
  if (held.isNotEmpty) {
    for (final t
        in await (personal.select(
              personal.transactions,
            )..where((t) => t.accountId.isIn(held.keys) & t.linkId.isNotNull()))
            .get()) {
      final link = t.linkId!;
      if (!_paired(link) || there.contains(link)) continue;
      final line = held[t.accountId]!.linkedAccountId;
      if (line == null) continue;
      out.add(
        OneSidedPayment(
          link: link,
          kind: _kindOfLink(link),
          at: t.occurredAt,
          amountMinor: t.amountMinor,
          // Held for down in Personal is money out of the business.
          inflow: t.direction == TransactionDirection.outflow,
          currency: t.currency,
          lineAccountId: line,
          code: t.receiptNo,
        ),
      );
    }
  }
  return out..sort((a, b) => a.at.compareTo(b.at));
}

/// What [business] has on the owner's accounts in Personal that Personal
/// has no side of: Personal was restored from an older backup.
Future<List<OneSidedPayment>> missingInPersonal({
  required AppDatabase personal,
  required AppDatabase business,
}) async {
  final records = {
    for (final r in await personal.select(personal.balanceRecords).get())
      r.linkId,
  };
  final linked = {
    for (final t in await (personal.select(
      personal.transactions,
    )..where((t) => t.linkId.isNotNull())).get())
      t.linkId!,
  };
  final owners = {
    for (final a
        in await (business.select(business.accounts)..where(
              (a) =>
                  a.type.equalsValue(AccountType.ownersAccount) &
                  a.linkedSpaceId.equals(personalSpaceId),
            ))
            .get())
      a.id: a,
  };
  if (owners.isEmpty) return const [];
  final categories = {
    for (final c in await business.select(business.categories).get()) c.id: c,
  };
  final out = <OneSidedPayment>[];
  for (final t
      in await (business.select(
            business.transactions,
          )..where((t) => t.accountId.isIn(owners.keys) & t.linkId.isNotNull()))
          .get()) {
    final link = t.linkId!;
    final kind = _kindOfLink(link);
    final found = kind == OneSidedKind.switched
        ? records.contains(link) || linked.contains(link)
        : linked.contains(link);
    if (found) continue;
    final line = owners[t.accountId]!.linkedAccountId;
    if (line == null) continue;
    final category = categories[t.categoryOverrideId ?? t.autoCategoryId];
    out.add(
      OneSidedPayment(
        link: link,
        kind: kind,
        at: t.occurredAt,
        amountMinor: t.amountMinor,
        inflow: t.direction == TransactionDirection.inflow,
        currency: t.currency,
        feeMinor: t.feeMinor,
        lineAccountId: line,
        code: t.receiptNo,
        name: t.counterpartyName,
        categoryName: category?.name,
        categoryKey: category?.key,
      ),
    );
  }
  return out..sort((a, b) => a.at.compareTo(b.at));
}

/// "Make them again in" the business: each payment comes back on the owner's
/// account there with its amount, time, fee and code. Names and
/// categories were only in the business: money in comes back as Sales,
/// money out as Not yet sorted; Pay yourself and Put money in come back as
/// what they were.
Future<int> remakeInBusiness({
  required AppDatabase personal,
  required AppDatabase business,
  required List<OneSidedPayment> payments,
}) async {
  var made = 0;
  await business.transaction(() async {
    for (final p in payments) {
      final line = await (personal.select(
        personal.accounts,
      )..where((a) => a.id.equals(p.lineAccountId))).getSingleOrNull();
      if (line == null) continue;
      final done = await (business.select(
        business.transactions,
      )..where((t) => t.linkId.equals(p.link))).get();
      if (done.isNotEmpty) continue;
      final owners = await ensureOwnersAccount(
        business,
        spaceId: personalSpaceId,
        account: line,
        spaceName: 'Personal',
      );
      final category = switch (p.kind) {
        OneSidedKind.switched =>
          p.inflow ? await ensureCategory(business, salesSeed) : null,
        OneSidedKind.pay => await ensureCategory(business, ownerPaySeed),
        OneSidedKind.putIn => await ensureCategory(business, ownerCapitalSeed),
        OneSidedKind.part => null,
      };
      await business
          .into(business.transactions)
          .insert(
            TransactionsCompanion.insert(
              accountId: owners,
              occurredAt: p.at,
              amountMinor: p.amountMinor,
              direction: p.inflow
                  ? TransactionDirection.inflow
                  : TransactionDirection.outflow,
              kind: Value(
                p.kind == OneSidedKind.part
                    ? TransactionKind.correction
                    : p.kind == OneSidedKind.switched
                    ? (p.inflow
                          ? TransactionKind.received
                          : TransactionKind.sent)
                    : null,
              ),
              feeMinor: Value(p.feeMinor),
              currency: Value(p.currency),
              categoryOverrideId: Value(category),
              receiptNo: Value(p.code),
              source: p.kind == OneSidedKind.switched
                  ? TransactionSource.sms
                  : TransactionSource.manual,
              linkId: Value(p.link),
              linkedSpaceId: const Value(personalSpaceId),
            ),
          );
      made++;
    }
  });
  return made;
}

/// "They were mine": what Personal kept for the business becomes
/// Personal's own again. Each balance record turns back into the payment
/// on its account, with what its message said, and not yet sorted; Pay
/// yourself, Put money in and corrections of the business's part on the
/// line are undone. Held for the business goes down by all of it.
Future<int> wereMine({
  required AppDatabase personal,
  required String businessId,
  required List<OneSidedPayment> payments,
}) async {
  final links = {for (final p in payments) p.link};
  var done = 0;
  await personal.transaction(() async {
    for (final r
        in await (personal.select(personal.balanceRecords)..where(
              (r) => r.spaceId.equals(businessId) & r.linkId.isIn(links),
            ))
            .get()) {
      await personal
          .into(personal.transactions)
          .insert(
            TransactionsCompanion.insert(
              accountId: r.accountId,
              occurredAt: r.occurredAt,
              amountMinor: r.amountMinor,
              direction: r.direction,
              kind: Value(r.kind),
              feeMinor: Value(r.feeMinor),
              currency: Value(r.currency),
              receiptNo: Value(r.receiptNo),
              source: TransactionSource.sms,
              messageHash: Value(r.messageHash),
              twinMessageHash: Value(r.twinMessageHash),
              dedupeKey: Value(r.dedupeKey),
              balanceAfterMinor: Value(r.balanceAfterMinor),
              claimedBalanceMinor: Value(r.claimedBalanceMinor),
              owedAfterMinor: Value(r.owedAfterMinor),
              owedDueAt: Value(r.owedDueAt),
            ),
          );
      final hashes = [?r.messageHash, ?r.twinMessageHash];
      if (hashes.isNotEmpty) {
        await (personal.delete(
          personal.setAsideMessages,
        )..where((m) => m.messageHash.isIn(hashes))).go();
      }
      await (personal.delete(
        personal.balanceRecords,
      )..where((x) => x.id.equals(r.id))).go();
      done++;
    }
    final paired = [
      for (final l in links)
        if (_paired(l)) l,
    ];
    if (paired.isNotEmpty) {
      done += await (personal.delete(
        personal.transactions,
      )..where((t) => t.linkId.isIn(paired))).go();
    }
  });
  return done;
}

/// "Make them again in Personal": each payment the business has on the
/// owner's account comes back on Personal's side in full. A switched
/// payment is a balance record on its account again (Personal's own copy
/// of it, if the older backup still has one, is switched away as it was);
/// Pay yourself and Put money in on the line are on Held for the business
/// again. No other row is added to Personal.
Future<int> remakeInPersonal({
  required AppDatabase personal,
  required String businessId,
  required String businessName,
  required List<OneSidedPayment> payments,
}) async {
  var made = 0;
  await personal.transaction(() async {
    for (final p in payments) {
      final line = await (personal.select(
        personal.accounts,
      )..where((a) => a.id.equals(p.lineAccountId))).getSingleOrNull();
      if (line == null) continue;
      final held = await ensureHeldForAccount(
        personal,
        spaceId: businessId,
        account: line,
        spaceName: businessName,
      );
      if (p.kind != OneSidedKind.switched) {
        final category = switch (p.kind) {
          OneSidedKind.pay => await ensureCategory(
            personal,
            payFromBusinessSeed,
          ),
          OneSidedKind.putIn => await ensureCategory(
            personal,
            putIntoBusinessSeed,
          ),
          _ => null,
        };
        await personal
            .into(personal.transactions)
            .insert(
              TransactionsCompanion.insert(
                accountId: held,
                occurredAt: p.at,
                amountMinor: p.amountMinor,
                // Money in to the business is Held for going up.
                direction: p.inflow
                    ? TransactionDirection.outflow
                    : TransactionDirection.inflow,
                kind: Value(
                  p.kind == OneSidedKind.part
                      ? TransactionKind.correction
                      : null,
                ),
                currency: Value(p.currency),
                source: TransactionSource.manual,
                counterpartyName: Value(businessName),
                categoryOverrideId: Value(category),
                linkId: Value(p.link),
                linkedSpaceId: Value(businessId),
              ),
            );
        made++;
        continue;
      }
      // Personal's own copy, when the older backup still has the payment.
      final own = p.code == null
          ? null
          : await (personal.select(personal.transactions)
                  ..where(
                    (t) =>
                        t.accountId.equals(line.id) &
                        t.receiptNo.equals(p.code!) &
                        t.amountMinor.equals(p.amountMinor),
                  )
                  ..limit(1))
                .getSingleOrNull();
      await personal
          .into(personal.balanceRecords)
          .insert(
            BalanceRecordsCompanion.insert(
              accountId: line.id,
              occurredAt: own?.occurredAt ?? p.at,
              amountMinor: p.amountMinor,
              direction: p.inflow
                  ? TransactionDirection.inflow
                  : TransactionDirection.outflow,
              kind: Value(own?.kind),
              feeMinor: Value(own?.feeMinor ?? p.feeMinor),
              currency: Value(p.currency),
              receiptNo: Value(p.code),
              dedupeKey: Value(own?.dedupeKey),
              messageHash: Value(own?.messageHash),
              twinMessageHash: Value(own?.twinMessageHash),
              balanceAfterMinor: Value(own?.balanceAfterMinor),
              claimedBalanceMinor: Value(own?.claimedBalanceMinor),
              owedAfterMinor: Value(own?.owedAfterMinor),
              owedDueAt: Value(own?.owedDueAt),
              transactionId: Value(own?.id),
              linkId: p.link,
              spaceId: businessId,
            ),
          );
      if (own != null) {
        await setAsideMessagesOf(personal, [own.id]);
        await (personal.delete(
          personal.transactions,
        )..where((t) => t.id.equals(own.id))).go();
      }
      made++;
    }
  });
  return made;
}

/// The restore check's state in a restored space: when its backup was
/// made, and the links the owner chose to leave apart.
class RestoreCheck {
  const RestoreCheck({this.backupAt, this.apart = const {}});

  final DateTime? backupAt;
  final Set<String> apart;

  static Future<RestoreCheck?> read(AppDatabase db) async {
    final json = await DriftAppSettingsRepository(db).readJson(restoreCheckKey);
    if (json == null) return null;
    final at = json['backupAtMs'];
    final apart = json['apart'];
    return RestoreCheck(
      backupAt: at is int
          ? DateTime.fromMillisecondsSinceEpoch(at, isUtc: true)
          : null,
      apart: {
        if (apart is List)
          for (final l in apart)
            if (l is String) l,
      },
    );
  }

  Future<void> save(AppDatabase db) => DriftAppSettingsRepository(db)
      .writeJson(restoreCheckKey, {
        'backupAtMs': ?backupAt?.millisecondsSinceEpoch,
        'apart': apart.toList()..sort(),
      });

  /// Marks [db]'s space as restored from a backup made at [backupAt], so
  /// it checks its linked sides once.
  /// It is only a check: should the space not open, the restore stands
  /// and nothing is asked.
  static Future<void> mark(
    AppDatabase Function() db,
    DateTime? backupAt,
  ) async {
    try {
      await RestoreCheck(backupAt: backupAt).save(db());
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Could not mark the restore: $error');
    }
  }

  /// The check is done: nothing left on one side only.
  static Future<void> clear(AppDatabase db) => (db.delete(
    db.appSettings,
  )..where((s) => s.key.equals(restoreCheckKey))).go();
}
