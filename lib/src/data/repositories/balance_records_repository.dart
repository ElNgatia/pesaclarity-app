import '../../domain/ledger/ledger_entry.dart';
import '../../domain/spaces/money_between_spaces.dart';
import '../database/app_database.dart';

/// Reads the balance records a space keeps (decision 0027, section 2): what
/// each payment switched to another space left on its account where the
/// account lives. Only the journal and balances read them, never a list,
/// total, report, search or export.
class BalanceRecordsReader {
  BalanceRecordsReader(this._db);

  final AppDatabase _db;

  /// The records of [accountIds], or of every account, as ledger entries
  /// for the journal and balances: each carries the Held for account it
  /// posts against, and its id made negative (see
  /// [LedgerEntry.heldForAccountId]).
  Future<List<LedgerEntry>> ledgerEntries({Set<int>? accountIds}) async {
    final query = _db.select(_db.balanceRecords);
    if (accountIds != null) query.where((r) => r.accountId.isIn(accountIds));
    final records = await query.get();
    if (records.isEmpty) return const [];
    final held = await heldForAccounts(_db);
    return [
      for (final r in records)
        LedgerEntry(
          id: -r.id,
          accountId: r.accountId,
          occurredAt: r.occurredAt,
          amountMinor: r.amountMinor,
          direction: r.direction,
          kind: r.kind ?? TransactionKind.bank,
          currency: r.currency,
          feeMinor: r.feeMinor,
          balanceAfterMinor: r.balanceAfterMinor,
          claimedBalanceMinor: r.claimedBalanceMinor,
          owedAfterMinor: r.owedAfterMinor,
          owedDueAt: r.owedDueAt,
          linkedSpaceId: r.spaceId,
          // A record always has its Held for account (see
          // `ensureHeldForAccount`); 0 keeps one that lost it apart.
          heldForAccountId: held[(r.spaceId, r.accountId)] ?? 0,
          placeId: r.transactionId,
        ),
    ];
  }
}

/// Each Held for account in [db] by the space it holds for and the account
/// the money is on.
Future<Map<(String, int), int>> heldForAccounts(AppDatabase db) async => {
  for (final a in await (db.select(
    db.accounts,
  )..where((a) => a.type.equalsValue(AccountType.heldForSpace))).get())
    if ((a.linkedSpaceId, a.linkedAccountId) case (
      final String space,
      final int account,
    ))
      (space, account): a.id,
};

/// The accounts [db] keeps for money between spaces (decision 0027), as
/// [MoneyBetweenSpaces] reads them.
Future<List<BetweenSpacesAccount>> betweenSpacesAccounts(
  AppDatabase db,
) async => [
  for (final a in await db.select(db.accounts).get())
    if (a.type.isBetweenSpaces && a.linkedSpaceId != null)
      BetweenSpacesAccount(
        id: a.id,
        type: a.type,
        spaceId: a.linkedSpaceId!,
        accountId: a.linkedAccountId,
        currency: a.currency,
      ),
];
