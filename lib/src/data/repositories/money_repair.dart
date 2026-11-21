import 'package:drift/drift.dart';

import '../../domain/spaces/money_between_spaces.dart';
import '../../domain/spaces/space.dart';
import '../database/app_database.dart';
import 'app_settings_repository.dart';
import 'balance_records_repository.dart';
import 'journal_repository.dart';
import 'space_move_repository.dart';

/// What the one-time repair of decision 0027 (section 8) did, for the sheet
/// that tells the person.
class MoneyRepairResult {
  const MoneyRepairResult({
    this.switched = const {},
    this.removed = const {},
    this.unsettled = 0,
    this.questions = const [],
  });

  factory MoneyRepairResult.fromJson(Map<String, Object?> json) {
    Map<String, Object?> map(Object? raw) =>
        raw is Map ? raw.cast<String, Object?>() : const {};
    return MoneyRepairResult(
      switched: {
        for (final MapEntry(:key, :value) in map(json['switched']).entries)
          if (value is int) key: value,
      },
      removed: {
        for (final MapEntry(:key, :value) in map(json['removed']).entries)
          if (value is List) key: [for (final n in value) '$n'],
      },
      unsettled: json['unsettled'] is int ? json['unsettled']! as int : 0,
      questions: [
        if (json['questions'] is List)
          for (final q in json['questions']! as List)
            ?RepairQuestion.fromJson(q),
      ],
    );
  }

  /// Payments put on the owner's account, by the space they are in.
  final Map<String, int> switched;

  /// Accounts removed from each space, by name: ones only moves made, for
  /// an account that lives in Personal.
  final Map<String, List<String>> removed;

  /// Moves that could not be settled: their space was deleted or cleared,
  /// so the payment is back in Personal as the owner's own.
  final int unsettled;

  /// "How much of your M-Pesa is Vegetable stall's today?", one for each
  /// business with a shared line whose balance the owner had typed.
  final List<RepairQuestion> questions;

  bool get changedAnything =>
      switched.values.any((n) => n > 0) ||
      removed.values.any((n) => n.isNotEmpty) ||
      unsettled > 0;

  Map<String, Object?> toJson() => {
    'switched': switched,
    'removed': removed,
    'unsettled': unsettled,
    'questions': [for (final q in questions) q.toJson()],
  };

  MoneyRepairResult withoutQuestion(RepairQuestion answered) =>
      MoneyRepairResult(
        switched: switched,
        removed: removed,
        unsettled: unsettled,
        questions: [
          for (final q in questions)
            if (q.spaceId != answered.spaceId ||
                q.ownersAccountId != answered.ownersAccountId)
              q,
        ],
      );
}

/// The one question for a business with a shared line: how much of the
/// owner's [line] is the business's today. [suggestedMinor] is what its
/// switched payments add up to.
class RepairQuestion {
  const RepairQuestion({
    required this.spaceId,
    required this.ownersAccountId,
    required this.line,
    required this.suggestedMinor,
  });

  static RepairQuestion? fromJson(Object? json) {
    if (json is! Map) return null;
    final space = json['spaceId'];
    final account = json['ownersAccountId'];
    final line = json['line'];
    final suggested = json['suggestedMinor'];
    if (space is! String ||
        account is! int ||
        line is! String ||
        suggested is! int) {
      return null;
    }
    return RepairQuestion(
      spaceId: space,
      ownersAccountId: account,
      line: line,
      suggestedMinor: suggested,
    );
  }

  final String spaceId;
  final int ownersAccountId;
  final String line;
  final int suggestedMinor;

  Map<String, Object?> toJson() => {
    'spaceId': spaceId,
    'ownersAccountId': ownersAccountId,
    'line': line,
    'suggestedMinor': suggestedMinor,
  };
}

/// Personal's setting that holds the repair's state.
const moneyRepairKey = 'repair.moneyBetweenSpaces';

/// Where the repair stands, in Personal's settings: not run, run with a
/// result still to show, or done.
class MoneyRepairState {
  const MoneyRepairState({this.ran = false, this.shown = false, this.result});

  factory MoneyRepairState.fromJson(Map<String, Object?>? json) =>
      MoneyRepairState(
        ran: json?['ran'] == true,
        shown: json?['shown'] == true,
        result: json?['result'] is Map
            ? MoneyRepairResult.fromJson(
                (json!['result']! as Map).cast<String, Object?>(),
              )
            : null,
      );

  final bool ran;

  /// Whether the person has seen what it did.
  final bool shown;
  final MoneyRepairResult? result;

  Map<String, Object?> toJson() => {
    'ran': ran,
    'shown': shown,
    'result': ?result?.toJson(),
  };
}

/// The one-time repair of records from before money between spaces
/// (decision 0027, section 8; owner's decision 8). A payment answered
/// "Business sale", or moved by hand, was copied into the other space with
/// the wallet's balance and remembered in Personal (`moved_transactions`).
/// For each such marker:
///
/// 1. it finds the copy in the other space;
/// 2. it puts a balance record back on the account where the account lives,
///    from what the copy holds;
/// 3. it turns the copy into the linked entry on the owner's account, its
///    balance dropped;
/// 4. it removes the marker, and both journals are rebuilt.
///
/// An account in a business that only moves made, for an account that
/// lives in Personal, is removed; where the owner had typed an opening
/// balance or a Set balance on it, one question is kept for that business.
/// A marker whose space is gone, or whose copy is gone, cannot be settled:
/// the marker goes, so the payment can come back to Personal as the
/// owner's own. Running it again changes nothing.
class MoneyRepair {
  MoneyRepair({
    required this.personal,
    required this.spaces,
    required this.open,
  });

  final AppDatabase personal;

  /// The spaces on this phone, Personal first.
  final List<Space> spaces;

  /// Opens a space's database; says whether the caller must close it.
  final Future<(AppDatabase, bool)> Function(String spaceId) open;

  /// Whether anything is there to repair: markers in Personal, or an
  /// account in another space that is Personal's line.
  Future<bool> needed() async {
    if ((await personal.select(personal.movedTransactions).get()).isNotEmpty) {
      return true;
    }
    final lines = await _personalLines();
    if (lines.isEmpty) return false;
    for (final space in spaces) {
      if (space.id == personalSpaceId) continue;
      final (db, close) = await open(space.id);
      try {
        if ((await _copiedAccounts(db, lines)).isNotEmpty) return true;
      } finally {
        if (close) await db.close();
      }
    }
    return false;
  }

  /// The institutions Personal reads.
  Future<Set<String>> _personalLines() async => {
    for (final s in await personal.select(personal.selectedInstitutions).get())
      s.institutionId,
  };

  /// Accounts in [db] for an institution Personal reads and [db] does not:
  /// only moves made them.
  Future<List<Account>> _copiedAccounts(
    AppDatabase db,
    Set<String> personalLines,
  ) async {
    final own = {
      for (final s in await db.select(db.selectedInstitutions).get())
        s.institutionId,
    };
    return [
      for (final a in await db.select(db.accounts).get())
        if (a.institutionId case final i?
            when personalLines.contains(i) &&
                !own.contains(i) &&
                !a.type.isBetweenSpaces)
          a,
    ];
  }

  Future<MoneyRepairResult> run() async {
    final markers = await personal.select(personal.movedTransactions).get();
    final listed = {for (final s in spaces) s.id: s};
    final personalLines = await _personalLines();
    final switched = <String, int>{};
    final removed = <String, List<String>>{};
    final questions = <RepairQuestion>[];
    var unsettled = 0;

    for (final m in markers) {
      if (!listed.containsKey(m.spaceId) || m.spaceId == personalSpaceId) {
        unsettled++;
        await _drop(m);
      }
    }

    for (final space in spaces) {
      if (space.id == personalSpaceId) continue;
      final (db, close) = await open(space.id);
      try {
        var count = 0;
        for (final m in markers.where((m) => m.spaceId == space.id)) {
          final settled = await _settle(m, db, space);
          if (settled) {
            count++;
          } else {
            unsettled++;
          }
          await _drop(m);
        }
        if (count > 0) switched[space.id] = count;

        // Accounts only moves made, for a line that lives in Personal.
        for (final account in await _copiedAccounts(db, personalLines)) {
          final rows = await (db.select(
            db.transactions,
          )..where((t) => t.accountId.equals(account.id))).get();
          final corrections = rows.where(
            (t) => t.kind == TransactionKind.correction,
          );
          if (rows.length != corrections.length) continue;
          final typed =
              account.openingBalanceMinor != 0 || corrections.isNotEmpty;
          await (db.delete(
            db.transactions,
          )..where((t) => t.accountId.equals(account.id))).go();
          await (db.delete(
            db.accounts,
          )..where((a) => a.id.equals(account.id))).go();
          (removed[space.id] ??= []).add(account.name);
          if (!typed) continue;
          final line = await _personalAccountFor(account);
          if (line == null) continue;
          final owners = await ensureOwnersAccount(
            db,
            spaceId: personalSpaceId,
            account: line,
            spaceName: 'Personal',
          );
          final between = MoneyBetweenSpaces.of(
            await betweenSpacesAccounts(db),
            await JournalRepository(db).read(),
          );
          questions.add(
            RepairQuestion(
              spaceId: space.id,
              ownersAccountId: owners,
              line: line.name,
              suggestedMinor: between.onOwnersAccounts.entries
                  .where((e) => e.key.id == owners)
                  .fold(0, (sum, e) => sum + e.value),
            ),
          );
        }
        await JournalRepository.markForRebuild(db);
      } finally {
        if (close) await db.close();
      }
    }
    await JournalRepository.markForRebuild(personal);
    return MoneyRepairResult(
      switched: switched,
      removed: removed,
      unsettled: unsettled,
      questions: questions,
    );
  }

  /// Personal's account that [copied], an account in another space, was
  /// made for: the same institution, number and currency.
  Future<Account?> _personalAccountFor(Account copied) async {
    final accounts =
        await (personal.select(personal.accounts)..where(
              (a) =>
                  a.institutionId.equals(copied.institutionId!) &
                  a.currency.equals(copied.currency),
            ))
            .get();
    return accounts.where((a) => a.reference == copied.reference).firstOrNull ??
        accounts.firstOrNull;
  }

  Future<void> _drop(MovedTransaction m) =>
      (personal.delete(personal.movedTransactions)..where(
            (t) =>
                t.accountId.equals(m.accountId) &
                t.dedupeKey.equals(m.dedupeKey),
          ))
          .go();

  /// Steps 1 to 3 for marker [m] in [db]; false when its copy is gone.
  Future<bool> _settle(MovedTransaction m, AppDatabase db, Space space) async {
    final line = await (personal.select(
      personal.accounts,
    )..where((a) => a.id.equals(m.accountId))).getSingleOrNull();
    if (line == null) return false;
    final copy =
        await (db.select(db.transactions)
              ..where((t) => t.dedupeKey.equals(m.dedupeKey))
              ..limit(1))
            .getSingleOrNull();
    if (copy == null) return false;
    final link = 'switch:$personalSpaceId:${m.accountId}:${m.dedupeKey}';
    await personal.transaction(() async {
      await ensureHeldForAccount(
        personal,
        spaceId: space.id,
        account: line,
        spaceName: space.name,
      );
      final kept = await (personal.select(
        personal.balanceRecords,
      )..where((r) => r.linkId.equals(link))).getSingleOrNull();
      if (kept != null) return;
      await personal
          .into(personal.balanceRecords)
          .insert(
            BalanceRecordsCompanion.insert(
              accountId: line.id,
              occurredAt: copy.occurredAt,
              amountMinor: copy.amountMinor,
              direction: copy.direction,
              kind: Value(copy.kind),
              feeMinor: Value(copy.feeMinor),
              currency: Value(copy.currency),
              receiptNo: Value(copy.receiptNo),
              dedupeKey: Value(copy.dedupeKey),
              messageHash: Value(copy.messageHash),
              twinMessageHash: Value(copy.twinMessageHash),
              balanceAfterMinor: Value(copy.balanceAfterMinor),
              claimedBalanceMinor: Value(copy.claimedBalanceMinor),
              owedAfterMinor: Value(copy.owedAfterMinor),
              owedDueAt: Value(copy.owedDueAt),
              linkId: link,
              spaceId: space.id,
            ),
          );
    });
    await db.transaction(() async {
      final owners = await ensureOwnersAccount(
        db,
        spaceId: personalSpaceId,
        account: line,
        spaceName: 'Personal',
      );
      await (db.update(
        db.transactions,
      )..where((t) => t.id.equals(copy.id))).write(
        TransactionsCompanion(
          accountId: Value(owners),
          balanceAfterMinor: const Value(null),
          claimedBalanceMinor: const Value(null),
          owedAfterMinor: const Value(null),
          owedDueAt: const Value(null),
          messageHash: const Value(null),
          twinMessageHash: const Value(null),
          transferPairId: const Value(null),
          linkId: Value(link),
          linkedSpaceId: const Value(personalSpaceId),
        ),
      );
    });
    return true;
  }
}

/// Sets how much of the owner's line is [spaceId]'s (decision 0027,
/// section 3, step 5; the repair's one question): a linked pair of
/// corrections, Owner's account up in the business and Held for up in
/// Personal, each against Balance corrections. The wallet is not touched.
Future<void> setSpacePart({
  required AppDatabase personal,
  required AppDatabase business,
  required String businessId,
  required String businessName,
  required int ownersAccountId,
  required int partMinor,
  required DateTime at,
}) async {
  final owners = await (business.select(
    business.accounts,
  )..where((a) => a.id.equals(ownersAccountId))).getSingle();
  final line = await (personal.select(
    personal.accounts,
  )..where((a) => a.id.equals(owners.linkedAccountId!))).getSingle();
  final current =
      MoneyBetweenSpaces.of(
            await betweenSpacesAccounts(business),
            await JournalRepository(business).read(),
          ).onOwnersAccounts.entries
          .where((e) => e.key.id == ownersAccountId)
          .fold(0, (sum, e) => sum + e.value);
  final diff = partMinor - current;
  if (diff == 0) return;
  final link = 'part:$businessId:${at.microsecondsSinceEpoch}';
  await personal.transaction(() async {
    final held = await ensureHeldForAccount(
      personal,
      spaceId: businessId,
      account: line,
      spaceName: businessName,
    );
    await personal
        .into(personal.transactions)
        .insert(
          TransactionsCompanion.insert(
            accountId: held,
            occurredAt: at,
            amountMinor: diff.abs(),
            // Held for up is money the owner's own part gives the business.
            direction: diff > 0
                ? TransactionDirection.outflow
                : TransactionDirection.inflow,
            kind: const Value(TransactionKind.correction),
            currency: Value(owners.currency),
            source: TransactionSource.manual,
            linkId: Value(link),
            linkedSpaceId: Value(businessId),
          ),
        );
  });
  await business
      .into(business.transactions)
      .insert(
        TransactionsCompanion.insert(
          accountId: ownersAccountId,
          occurredAt: at,
          amountMinor: diff.abs(),
          direction: diff > 0
              ? TransactionDirection.inflow
              : TransactionDirection.outflow,
          kind: const Value(TransactionKind.correction),
          currency: Value(owners.currency),
          source: TransactionSource.manual,
          linkId: Value(link),
          linkedSpaceId: const Value(personalSpaceId),
        ),
      );
}

/// Reads and saves the repair's state in Personal's settings.
class MoneyRepairStore {
  MoneyRepairStore(AppDatabase personal)
    : _settings = DriftAppSettingsRepository(personal);

  final AppSettingsRepository _settings;

  Future<MoneyRepairState> read() async =>
      MoneyRepairState.fromJson(await _settings.readJson(moneyRepairKey));

  Future<void> save(MoneyRepairState state) =>
      _settings.writeJson(moneyRepairKey, state.toJson());
}

/// What Personal holds for [spaceId] on its accounts, by Held for account,
/// zeros left out.
Future<Map<int, int>> heldForSpaceIn(
  AppDatabase personal,
  String spaceId,
) async {
  final accounts = [
    for (final a in await betweenSpacesAccounts(personal))
      if (a.spaceId == spaceId && a.type == AccountType.heldForSpace) a,
  ];
  if (accounts.isEmpty) return const {};
  final balances = await JournalRepository(personal).read();
  return {
    for (final a in accounts)
      if (balances.balanceOf(a.bookAccount, currency: a.currency)
          case final minor when minor != 0)
        a.id: minor,
  };
}

/// "It is mine now" when a business that still has money on the owner's
/// accounts is deleted or cleared (owner's decision 9): what Personal holds
/// for it is filed as pay from the business ([payCategoryId]); what it
/// owes the owner is let go, as a correction of its part. Held for it is
/// then nothing. "Keep it apart" changes nothing.
Future<void> settleHeldFor(
  AppDatabase personal, {
  required String spaceId,
  required String spaceName,
  required int payCategoryId,
  required DateTime at,
}) async {
  final held = await heldForSpaceIn(personal, spaceId);
  await personal.transaction(() async {
    for (final MapEntry(key: account, value: minor) in held.entries) {
      final currency = (await (personal.select(
        personal.accounts,
      )..where((a) => a.id.equals(account))).getSingle()).currency;
      await personal
          .into(personal.transactions)
          .insert(
            TransactionsCompanion.insert(
              accountId: account,
              occurredAt: at,
              amountMinor: minor.abs(),
              direction: minor > 0
                  ? TransactionDirection.inflow
                  : TransactionDirection.outflow,
              kind: Value(minor > 0 ? null : TransactionKind.correction),
              currency: Value(currency),
              source: TransactionSource.manual,
              counterpartyName: Value(spaceName),
              categoryOverrideId: Value(minor > 0 ? payCategoryId : null),
              linkId: Value('settle:$spaceId:${at.microsecondsSinceEpoch}'),
              linkedSpaceId: Value(spaceId),
            ),
          );
    }
  });
}
