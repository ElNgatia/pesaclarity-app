// The one-time repair of records from before money between spaces
// (decision 0027, section 8): payments moved by an earlier version, with
// the owner's wallet balance on the copy, are put right in both spaces.
// A replay of moved payments, an opening balance and a correction, from
// the audit's case (A, F1; B, B2). Made-up data only.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/data/database/space_databases.dart';
import 'package:pesaclarity/src/data/repositories/accounts_repository.dart';
import 'package:pesaclarity/src/data/repositories/app_settings_repository.dart';
import 'package:pesaclarity/src/data/repositories/balance_records_repository.dart';
import 'package:pesaclarity/src/data/repositories/balances_repair.dart';
import 'package:pesaclarity/src/data/repositories/journal_repository.dart';
import 'package:pesaclarity/src/data/repositories/money_repair.dart';
import 'package:pesaclarity/src/domain/spaces/kept_data.dart';
import 'package:pesaclarity/src/domain/spaces/money_between_spaces.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/features/spaces/application/space_manager.dart';
import 'package:pesaclarity/src/features/spaces/application/spaces_providers.dart';

import '../../helpers/spaces_harness.dart';
import '../../helpers/test_app.dart';

const _stall = Space(
  id: 'stall',
  name: 'Vegetable stall',
  kind: SpaceKind.business,
);

int _kes(int shillings) => shillings * 100;

Future<MoneyBetweenSpaces> _between(AppDatabase db) async =>
    MoneyBetweenSpaces.of(
      await betweenSpacesAccounts(db),
      await JournalRepository(db).read(),
    );

Future<int> _held(AppDatabase db) async =>
    (await JournalRepository(db).read()).totalHeldAt(
      await DriftAccountsRepository(db).openings(),
      at: DateTime.utc(2100),
      where: (_) => true,
    );

void main() {
  _leakThenSwitch();
  late AppDatabase personal;
  late AppDatabase business;
  late int wallet;
  late int copied;
  late MoneyRepair repair;

  Future<void> reads(AppDatabase db) => db
      .into(db.selectedInstitutions)
      .insert(
        SelectedInstitutionsCompanion.insert(
          institutionId: 'mpesa',
          selectedAt: DateTime.utc(2026),
        ),
      );

  /// A payment moved by an earlier version: gone from Personal, remembered
  /// there, and copied into the stall with the wallet's balance.
  Future<int> movedEarlier(
    String receipt,
    int amount,
    int balance, {
    bool inflow = true,
    DateTime? at,
  }) async {
    final key = '$receipt|$amount';
    await personal
        .into(personal.movedTransactions)
        .insert(
          MovedTransactionsCompanion.insert(
            accountId: wallet,
            dedupeKey: key,
            spaceId: _stall.id,
          ),
        );
    await personal
        .into(personal.setAsideMessages)
        .insert(SetAsideMessagesCompanion.insert(messageHash: 'h-$receipt'));
    return business
        .into(business.transactions)
        .insert(
          TransactionsCompanion.insert(
            accountId: copied,
            occurredAt: at ?? DateTime.utc(2026, 11, 18, 7),
            amountMinor: amount,
            direction: inflow
                ? TransactionDirection.inflow
                : TransactionDirection.outflow,
            kind: Value(
              inflow ? TransactionKind.received : TransactionKind.till,
            ),
            source: TransactionSource.sms,
            counterpartyName: const Value('GRACE WAMBUI'),
            receiptNo: Value(receipt),
            dedupeKey: Value(key),
            messageHash: Value('h-$receipt'),
            balanceAfterMinor: Value(balance),
          ),
        );
  }

  setUp(() async {
    personal = openTestDatabase();
    business = openTestDatabase();
    await business.becomeSpace(SpaceKind.business);
    await reads(personal);
    wallet = await personal
        .into(personal.accounts)
        .insert(
          AccountsCompanion.insert(
            name: 'M-Pesa',
            type: AccountType.mpesa,
            openingBalanceMinor: Value(_kes(37819)),
            openingDate: DateTime.utc(2026, 11),
            institutionId: const Value('mpesa'),
          ),
        );
    // The wallet's own message after the sale, still in Personal.
    await personal
        .into(personal.transactions)
        .insert(
          TransactionsCompanion.insert(
            accountId: wallet,
            occurredAt: DateTime.utc(2026, 11, 19, 7),
            amountMinor: _kes(1000),
            direction: TransactionDirection.outflow,
            kind: const Value(TransactionKind.sent),
            source: TransactionSource.sms,
            dedupeKey: const Value('TJA3'),
            balanceAfterMinor: Value(_kes(37469)),
          ),
        );
    // Only moves made the stall's M-Pesa.
    copied = await business
        .into(business.accounts)
        .insert(
          AccountsCompanion.insert(
            name: 'M-Pesa',
            type: AccountType.mpesa,
            openingDate: DateTime.utc(2026, 11, 18),
            institutionId: const Value('mpesa'),
          ),
        );
    repair = MoneyRepair(
      personal: personal,
      spaces: const [Space.personal, _stall],
      open: (id) async => (id == personalSpaceId ? personal : business, false),
    );
  });

  test('puts a moved sale right in both spaces', () async {
    final copy = await movedEarlier('TJA2', _kes(650), _kes(38469));
    // Before: the stall shows the owner's whole wallet (F1), Personal a gap.
    expect(await _held(business), _kes(38469));
    expect(await repair.needed(), isTrue);

    final result = await repair.run();

    expect(result.switched, {_stall.id: 1});
    expect(result.removed, {
      _stall.id: ['M-Pesa'],
    });
    expect(result.unsettled, 0);
    expect(result.questions, isEmpty, reason: 'nothing was typed');

    // 2. A balance record where the account lives, with the balance the
    // message printed.
    final record = await personal.select(personal.balanceRecords).getSingle();
    expect(record.accountId, wallet);
    expect(record.amountMinor, _kes(650));
    expect(record.balanceAfterMinor, _kes(38469));
    expect(record.messageHash, 'h-TJA2');
    expect(record.spaceId, _stall.id);
    // 3. The copy is the linked entry on the owner's account, no balance.
    final entry = await (business.select(
      business.transactions,
    )..where((t) => t.id.equals(copy))).getSingle();
    expect(entry.balanceAfterMinor, isNull);
    expect(entry.linkId, record.linkId);
    expect(entry.counterpartyName, 'GRACE WAMBUI');
    final owners = await (business.select(
      business.accounts,
    )..where((a) => a.id.equals(entry.accountId))).getSingle();
    expect(owners.type, AccountType.ownersAccount);
    // The stall's M-Pesa, made only by moves, is gone.
    expect(
      (await business.select(business.accounts).get()).map((a) => a.type),
      [AccountType.ownersAccount],
    );
    // 4. The marker is gone; the message stays set aside.
    expect(await personal.select(personal.movedTransactions).get(), isEmpty);
    expect(
      await personal.select(personal.setAsideMessages).get(),
      hasLength(1),
    );

    // The figures: the wallet whole in Personal with no gap, 650 of it the
    // stall's; the stall has 650 on the owner's M-Pesa; together the wallet.
    expect(await _held(personal), _kes(37469));
    expect(await JournalRepository(personal).openGaps(), isEmpty);
    expect((await _between(personal)).heldFor(_stall.id), _kes(650));
    expect(await _held(business), 0);
    expect((await _between(business)).onAccountsOf(personalSpaceId), _kes(650));

    // Running it again changes nothing.
    expect(await repair.needed(), isFalse);
    final again = await repair.run();
    expect(again.changedAnything, isFalse);
    expect(await personal.select(personal.balanceRecords).get(), hasLength(1));
  });

  test('asks once how much of the M-Pesa is the stall\'s where the owner '
      'had typed a balance, and the answer sets its part', () async {
    await movedEarlier('TJA2', _kes(650), _kes(38469));
    // Set balance on the stall's M-Pesa, typed by the owner.
    await business
        .into(business.transactions)
        .insert(
          TransactionsCompanion.insert(
            accountId: copied,
            occurredAt: DateTime.utc(2026, 11, 19, 9),
            amountMinor: _kes(35469),
            direction: TransactionDirection.outflow,
            kind: const Value(TransactionKind.correction),
            source: TransactionSource.manual,
            balanceAfterMinor: Value(_kes(3000)),
          ),
        );

    final result = await repair.run();

    expect(result.removed[_stall.id], ['M-Pesa']);
    final question = result.questions.single;
    expect(question.spaceId, _stall.id);
    expect(question.line, 'M-Pesa');
    expect(question.suggestedMinor, _kes(650));

    // The owner says KES 3,000 of the M-Pesa is the stall's.
    await setSpacePart(
      personal: personal,
      business: business,
      businessId: _stall.id,
      businessName: _stall.name,
      ownersAccountId: question.ownersAccountId,
      partMinor: _kes(3000),
      at: DateTime.utc(2026, 11, 21, 9),
    );
    expect(
      (await _between(business)).onAccountsOf(personalSpaceId),
      _kes(3000),
    );
    expect((await _between(personal)).heldFor(_stall.id), _kes(3000));
    expect(await _held(personal), _kes(37469), reason: 'the wallet untouched');
  });

  test('a move to a space that is gone cannot be settled: the marker goes, '
      'so the payment can come back as the owner\'s own', () async {
    await personal
        .into(personal.movedTransactions)
        .insert(
          MovedTransactionsCompanion.insert(
            accountId: wallet,
            dedupeKey: 'TJA9|65000',
            spaceId: 'deleted-shop',
          ),
        );
    final result = await repair.run();
    expect(result.unsettled, 1);
    expect(await personal.select(personal.movedTransactions).get(), isEmpty);
  });

  test('"It is mine now" files what Personal holds for a business as pay '
      'from it', () async {
    await movedEarlier('TJA2', _kes(650), _kes(38469));
    await repair.run();
    expect(await heldForSpaceIn(personal, _stall.id), isNotEmpty);

    final pay = await personal
        .into(personal.categories)
        .insert(
          CategoriesCompanion.insert(
            name: 'Salary from my business',
            type: CategoryType.income,
          ),
        );
    await settleHeldFor(
      personal,
      spaceId: _stall.id,
      spaceName: _stall.name,
      payCategoryId: pay,
      at: DateTime.utc(2026, 11, 21, 12),
    );
    expect(await heldForSpaceIn(personal, _stall.id), isEmpty);
    expect(await _held(personal), _kes(37469));
  });

  test('on the phone: it keeps a locked copy of every space for 30 days, '
      'runs once, and says what it did', () async {
    final (c, _) = await spacesOnFiles(clock: () => DateTime.utc(2026, 11, 21));
    final shopId = await c
        .read(spacesProvider.notifier)
        .add('Vegetable stall', SpaceKind.business);
    final personal = c.read(personalDatabaseProvider);
    final (shop, close) = await c.read(spaceDatabasesProvider).open(shopId);
    try {
      await personal
          .into(personal.selectedInstitutions)
          .insert(
            SelectedInstitutionsCompanion.insert(
              institutionId: 'mpesa',
              selectedAt: DateTime.utc(2026),
            ),
          );
      final line = await personal
          .into(personal.accounts)
          .insert(
            AccountsCompanion.insert(
              name: 'M-Pesa',
              type: AccountType.mpesa,
              openingDate: DateTime.utc(2026, 11),
              institutionId: const Value('mpesa'),
            ),
          );
      final copiedHere = await shop
          .into(shop.accounts)
          .insert(
            AccountsCompanion.insert(
              name: 'M-Pesa',
              type: AccountType.mpesa,
              openingDate: DateTime.utc(2026, 11),
              institutionId: const Value('mpesa'),
            ),
          );
      await personal
          .into(personal.movedTransactions)
          .insert(
            MovedTransactionsCompanion.insert(
              accountId: line,
              dedupeKey: 'K1',
              spaceId: shopId,
            ),
          );
      await shop
          .into(shop.transactions)
          .insert(
            TransactionsCompanion.insert(
              accountId: copiedHere,
              occurredAt: DateTime.utc(2026, 11, 18, 7),
              amountMinor: _kes(650),
              direction: TransactionDirection.inflow,
              source: TransactionSource.sms,
              dedupeKey: const Value('K1'),
              balanceAfterMinor: Value(_kes(38469)),
            ),
          );
    } finally {
      if (close) await shop.close();
    }

    final state = await c.read(spaceManagerProvider).repairMoneyBetweenSpaces();
    expect(state.ran, isTrue);
    expect(state.shown, isFalse, reason: 'the sheet is still to show');
    expect(state.result!.switched, {shopId: 1});
    final kept = await c.read(keptDataProvider.future);
    expect(kept.map((k) => (k.space.name, k.kind)), {
      ('Personal', KeptKind.beforeRepair),
      ('Vegetable stall', KeptKind.beforeRepair),
    });

    // Once only.
    final again = await c.read(spaceManagerProvider).repairMoneyBetweenSpaces();
    expect(again.result!.switched, {shopId: 1});
    expect(await c.read(keptDataProvider.future), hasLength(2));
  });
}

void _leakThenSwitch() {
  test('on the phone: the copies of messages stored in two spaces go '
      'first, and what the person kept becomes a switch, once', () async {
    final (c, _) = await spacesOnFiles(clock: () => DateTime.utc(2026, 11, 21));
    final shopId = await c
        .read(spacesProvider.notifier)
        .add('Vegetable stall', SpaceKind.business);
    final personal = c.read(personalDatabaseProvider);
    final (shop, close) = await c.read(spaceDatabasesProvider).open(shopId);
    try {
      await personal
          .into(personal.selectedInstitutions)
          .insert(
            SelectedInstitutionsCompanion.insert(
              institutionId: 'mpesa',
              selectedAt: DateTime.utc(2026),
            ),
          );
      Future<int> mpesa(AppDatabase db) => db
          .into(db.accounts)
          .insert(
            AccountsCompanion.insert(
              name: 'M-Pesa',
              type: AccountType.mpesa,
              openingDate: DateTime.utc(2026, 11),
              institutionId: const Value('mpesa'),
            ),
          );
      final line = await mpesa(personal);
      final copied = await mpesa(shop);
      final stock = await shop
          .into(shop.categories)
          .insert(
            CategoriesCompanion.insert(
              name: 'Test sales',
              type: CategoryType.income,
            ),
          );
      // Both spaces stored the same two messages before each was read in
      // one space; the shop filed the first as its own.
      for (final (db, account) in [(personal, line), (shop, copied)]) {
        for (final (key, day) in [('K1', 18), ('K2', 19)]) {
          await db
              .into(db.transactions)
              .insert(
                TransactionsCompanion.insert(
                  accountId: account,
                  occurredAt: DateTime.utc(2026, 11, day, 7),
                  amountMinor: _kes(650),
                  direction: TransactionDirection.inflow,
                  source: TransactionSource.sms,
                  dedupeKey: Value(key),
                  messageHash: Value('hash-$key'),
                  balanceAfterMinor: Value(_kes(38469 + day)),
                  categoryOverrideId: Value(
                    db == shop && key == 'K1' ? stock : null,
                  ),
                ),
              );
        }
      }
    } finally {
      if (close) await shop.close();
    }

    final state = await c.read(spaceManagerProvider).repairMoneyBetweenSpaces();
    // The leak repair took the plain copy out of the shop and Personal's
    // copy of the one the shop made its own, as a move; this repair then
    // switched that one: on the owner's account there, a balance record
    // here.
    expect(state.result!.switched, {shopId: 1});
    final [record] = await personal.select(personal.balanceRecords).get();
    expect(record.dedupeKey, 'K1');
    expect(record.spaceId, shopId);
    expect(await personal.select(personal.movedTransactions).get(), isEmpty);
    expect(
      [
        for (final t in await personal.select(personal.transactions).get())
          t.dedupeKey,
      ],
      ['K2'],
    );
    final (again, closeAgain) = await c
        .read(spaceDatabasesProvider)
        .open(shopId);
    try {
      final [switched] = await again.select(again.transactions).get();
      expect(switched.dedupeKey, 'K1');
      expect(switched.linkId, isNotNull);
      expect(switched.messageHash, isNull);
      // Each repair ran once in each space.
      for (final db in [personal, again]) {
        expect(
          await DriftAppSettingsRepository(db).readJson(spaceLeakRepairKey),
          {'version': spaceLeakRepairVersion},
        );
      }
      // The message stays held where its account lives, so a space that
      // reads M-Pesa later never stores it again.
      expect(await heldIn(personal, {'hash-K1', 'hash-K2'}), {
        'hash-K1',
        'hash-K2',
      });
      expect(await heldIn(again, {'hash-K1'}), isEmpty);
    } finally {
      if (closeAgain) await again.close();
    }
    final second = await c
        .read(spaceManagerProvider)
        .repairMoneyBetweenSpaces();
    expect(second.result!.switched, {shopId: 1});
    expect(await personal.select(personal.balanceRecords).get(), hasLength(1));
  });
}
