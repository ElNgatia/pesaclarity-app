import '../../../data/database/app_database.dart';
import '../../../data/repositories/journal_repository.dart';
import '../../../data/repositories/transactions_repository.dart';
import '../../../domain/firefly/firefly_mapping.dart';
import '../../../domain/ledger/ledger_entry.dart';
import '../../../domain/ledger/ledger_role.dart';
import '../../../domain/spaces/space.dart';

/// Everything one space sends to Firefly III, read from its records and
/// journal at one moment.
class FireflySpaceSnapshot {
  const FireflySpaceSnapshot({
    required this.parts,
    required this.accounts,
    required this.openings,
    required this.balances,
  });

  /// The parts of each transaction on or after Send from, by its id. A
  /// transaction whose money is sent by its other side has none.
  final Map<int, List<FireflyPart>> parts;

  /// Every Firefly III account the parts use or that opens with money, by
  /// key.
  final Map<String, FireflyAccountSpec> accounts;

  /// Each own account's opening balance on the Send from day, by key: an
  /// asset's balance, or what a liability says is owed.
  final Map<String, int> openings;

  /// Each own account's balance in Pesa Clarity's journal now, by key, as
  /// [openings] counts it. Firefly III should show the same.
  final Map<String, int> balances;
}

/// Reads [space]'s transactions from [from] on, from [db], as Firefly III
/// parts. The journal is brought up to date first.
Future<FireflySpaceSnapshot> readFireflySpace(
  AppDatabase db, {
  required Space space,
  required DateTime from,
}) async {
  await JournalRepository(db).sync();
  final naming = FireflyNames(
    spaceName: space.name,
    personal: space.id == personalSpaceId,
  );
  final accountRows = await db.select(db.accounts).get();
  final names = <String, int>{};
  for (final a in accountRows) {
    names[a.name] = (names[a.name] ?? 0) + 1;
  }
  final accounts = {
    for (final a in accountRows)
      a.id: FireflyMoneyAccount(
        id: a.id,
        name: a.name,
        type: a.type,
        currency: a.currency,
        product: a.product,
        // Two accounts with one name: the later ones by their number.
        nameThere:
            names[a.name]! > 1 &&
                accountRows.firstWhere((b) => b.name == a.name).id != a.id
            ? '${a.name} ${a.id}'
            : a.name,
      ),
  };
  final categories = {
    for (final c in await db.select(db.categories).get()) c.id: c,
  };
  final tags = {for (final t in await db.select(db.tags).get()) t.id: t.name};
  final receipts = {
    for (final row
        in await (db.selectOnly(db.transactions)
              ..addColumns([db.transactions.id, db.transactions.receiptNo])
              ..where(db.transactions.receiptNo.isNotNull()))
            .get())
      row.read(db.transactions.id)!: row.read(db.transactions.receiptNo)!,
  };
  final entries = await DriftTransactionsRepository(db)
      .ledgerEntries(from: DateTime.utc(1970), to: DateTime.utc(9999));
  final byId = {for (final e in entries) e.id: e};

  // Each source's postings, netted: a reversal cancels what it reverses.
  final lines = <(String, int), Map<(String, String), int>>{};
  final before = <(String, String), int>{};
  final now = <(String, String), int>{};
  final rows = await db
      .customSelect(
        'SELECT j.source_kind AS kind, j.source_id AS sid, '
        'j.occurred_at AS at, p.account AS account, p.currency AS currency, '
        'p.amount_minor AS amount FROM postings p '
        'JOIN journal_entries j ON j.id = p.entry_id',
        readsFrom: {db.postings, db.journalEntries},
      )
      .get();
  final fromSeconds = from.millisecondsSinceEpoch ~/ 1000;
  for (final row in rows) {
    final kind = row.read<String>('kind');
    final account = row.read<String>('account');
    final currency = row.read<String>('currency');
    final amount = row.read<int>('amount');
    final key = (account, currency);
    final bySource = lines.putIfAbsent((kind, row.read<int>('sid')), () => {});
    bySource[key] = (bySource[key] ?? 0) + amount;
    now[key] = (now[key] ?? 0) + amount;
    // Openings count whenever they are dated: they start the account.
    if (row.read<int>('at') < fromSeconds || kind == 'opening') {
      before[key] = (before[key] ?? 0) + amount;
    }
  }

  List<FireflyPart> partsOf(LedgerEntry e) {
    final account = accounts[e.accountId];
    if (account == null) return const [];
    final own = lines[('transaction', e.id)] ?? const {};
    int line(String bookKey) => own[(bookKey, e.currency)] ?? 0;
    final transit = roleOf(e) == LedgerRole.ownTransfer
        ? 0
        : line('ownTransfers');
    final partner = e.transferPairId == null ? null : byId[e.transferPairId];
    final partnerAccount = partner == null ? null : accounts[partner.accountId];
    final paired =
        partner != null &&
        partnerAccount != null &&
        !partner.occurredAt.isBefore(from) == !e.occurredAt.isBefore(from);
    final categoryId = e.categoryId;
    final category = categoryId == null ? null : categories[categoryId];
    final gap =
        (lines[('balanceDifference', e.id)] ?? const {})[(
          'money:${e.accountId}',
          e.currency,
        )] ??
        0;
    return fireflyParts(
      FireflyTransactionFacts(
        entry: e,
        account: account,
        journalMoneyMinor: line('money:${e.accountId}') + transit,
        journalFulizaMinor: -line('fulizaOwed:${e.accountId}'),
        journalBorrowedMinor: -line('borrowed'),
        partner: paired ? partner : null,
        partnerAccount: paired ? partnerAccount : null,
        categoryName: category?.name,
        categoryKey: category?.key,
        receipt: receipts[e.id],
        tagNames: [for (final id in e.tagIds) ?tags[id]]..sort(),
        gapMinor: gap,
      ),
      naming,
    );
  }

  final parts = <int, List<FireflyPart>>{};
  final specs = <String, FireflyAccountSpec>{};
  final earlier = <FireflyPart>[];
  for (final e in entries) {
    final mine = partsOf(e);
    for (final p in mine) {
      for (final a in p.accounts) {
        specs[a.key] = a;
      }
    }
    if (e.occurredAt.isBefore(from)) {
      earlier.addAll(mine);
    } else {
      parts[e.id] = mine;
    }
  }
  for (final a in accounts.values) {
    final spec = naming.asset(a);
    specs[spec.key] = spec;
    if (a.canOweFuliza) {
      final fuliza = naming.fuliza(a);
      specs[fuliza.key] = fuliza;
    }
  }

  // An own account's balance from the journal, by Firefly III key; lenders
  // have no account of their own there, so they count what their parts
  // moved.
  Map<String, int> balancesFrom(
    Map<(String, String), int> sums,
    Iterable<FireflyPart> lenderParts,
  ) {
    final out = <String, int>{};
    for (final spec in specs.values) {
      final key = spec.key;
      final currency = spec.currency;
      if (currency == null) continue;
      final [kind, id, ...] = [...key.split(':'), ''];
      final value = switch (kind) {
        'money' => sums[('money:$id', currency)],
        'fuliza' => switch (sums[('fulizaOwed:$id', currency)]) {
          final v? => -v,
          null => null,
        },
        'savings' => sums[('savings', currency)],
        'transit' => sums[('ownTransfers', currency)],
        _ => null,
      };
      if (value != null && value != 0) out[key] = value;
    }
    for (final MapEntry(:key, :value) in fireflyDeltas(lenderParts).entries) {
      if (key.startsWith('lender:') && value != 0) {
        out[key] = (out[key] ?? 0) + value;
      }
    }
    return out;
  }

  return FireflySpaceSnapshot(
    parts: parts,
    accounts: specs,
    openings: balancesFrom(before, earlier),
    balances: balancesFrom(now, [
      ...earlier,
      for (final p in parts.values) ...p,
    ]),
  );
}
