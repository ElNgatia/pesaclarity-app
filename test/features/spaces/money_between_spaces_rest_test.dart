// The rest of decision 0027 through the app's own code, on two real
// databases: Put money in, Pay yourself by bank with "Where it lands", the
// restore check and the question on Clear data. Each checks both spaces'
// balances, In and Out, and that every journal entry balances with nothing
// in Not yet sorted. Made-up data only.
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/time/clock.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/data/repositories/app_settings_repository.dart';
import 'package:pesaclarity/src/data/repositories/balance_records_repository.dart';
import 'package:pesaclarity/src/data/repositories/category_seeds.dart';
import 'package:pesaclarity/src/data/repositories/journal_repository.dart';
import 'package:pesaclarity/src/data/repositories/money_repair.dart';
import 'package:pesaclarity/src/data/repositories/restore_check.dart';
import 'package:pesaclarity/src/data/repositories/space_move_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/domain/books/book_account.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_totals.dart';
import 'package:pesaclarity/src/domain/spaces/money_between_spaces.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/domain/spaces/space_categories.dart';
import 'package:pesaclarity/src/features/sales/application/pay_yourself.dart';
import 'package:pesaclarity/src/features/sales/application/put_money_in.dart';
import 'package:pesaclarity/src/features/sales/application/sales_providers.dart';
import 'package:pesaclarity/src/features/spaces/application/restore_check_providers.dart';
import 'package:pesaclarity/src/features/spaces/application/space_manager.dart';
import 'package:pesaclarity/src/features/spaces/application/spaces_providers.dart';
import 'package:pesaclarity/src/features/spaces/data/space_files.dart';

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

Future<LedgerTotals> _totals(AppDatabase db) async => LedgerTotals.of(
  await DriftTransactionsRepository(db)
      .ledgerEntries(from: DateTime.utc(2026), to: DateTime.utc(2027)),
  from: DateTime.utc(2026),
  to: DateTime.utc(2027),
  currency: 'KES',
);

Future<int> _balance(AppDatabase db, BookAccount account) async =>
    (await JournalRepository(db).read()).balanceOf(account, currency: 'KES');

Future<void> _sound(AppDatabase db) async {
  expect(await JournalRepository(db).unbalanced(), isEmpty);
  expect(await _balance(db, BookAccount.notYetSorted), 0);
}

class _Files implements SpaceFiles {
  @override
  Future<void> deleteDatabase(String spaceId) async {}

  @override
  Future<void> eraseEverything() async {}

  @override
  Future<Directory> keptDirectory() async =>
      Directory.systemTemp.createTemp('kept');
}

void main() {
  late AppDatabase personal;
  late AppDatabase business;
  late ProviderContainer c;
  late int mpesa;
  late int equity;
  late int kcb;
  late DriftSpaceMoveRepository fromPersonal;
  final now = DateTime.utc(2026, 11, 21, 7, 12);

  setUp(() async {
    personal = openTestDatabase();
    business = openTestDatabase();
    await business.becomeSpace(SpaceKind.business);
    await DriftAppSettingsRepository(personal).writeJson(
      SpacesController.settingsKey,
      spacesToJson([Space.personal, _stall]),
    );
    c = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(business),
        personalDatabaseProvider.overrideWithValue(personal),
        mainDatabaseProvider.overrideWithValue(personal),
        clockProvider.overrideWithValue(() => now),
        activeSpaceIdProvider.overrideWith(() => ActiveSpaceId(_stall.id)),
        activeSpaceProvider.overrideWithValue(_stall),
        spaceFilesProvider.overrideWithValue(_Files()),
      ],
    );
    addTearDown(c.dispose);
    mpesa = await personal
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
    equity = await personal
        .into(personal.accounts)
        .insert(
          AccountsCompanion.insert(
            name: 'Equity bank',
            type: AccountType.bank,
            openingBalanceMinor: Value(_kes(20000)),
            openingDate: DateTime.utc(2026, 11),
            institutionId: const Value('equity'),
          ),
        );
    kcb = await business
        .into(business.accounts)
        .insert(
          AccountsCompanion.insert(
            name: 'KCB',
            type: AccountType.bank,
            openingBalanceMinor: Value(_kes(10000)),
            openingDate: DateTime.utc(2026, 11),
            institutionId: const Value('kcb'),
          ),
        );
    fromPersonal = DriftSpaceMoveRepository(
      personal,
      (_) async => (business, false),
      nameOf: (id) async => id == _stall.id ? _stall.name : 'Personal',
    );
  });

  /// A payment on Personal's M-Pesa, switched to the stall.
  Future<int> switched(
    int amount,
    int wallet, {
    required DateTime at,
    required String code,
    bool inflow = true,
  }) async {
    final id = await personal
        .into(personal.transactions)
        .insert(
          TransactionsCompanion.insert(
            accountId: mpesa,
            occurredAt: at,
            amountMinor: amount,
            direction: inflow
                ? TransactionDirection.inflow
                : TransactionDirection.outflow,
            kind: Value(
              inflow ? TransactionKind.received : TransactionKind.paybill,
            ),
            source: TransactionSource.sms,
            counterpartyName: const Value('GRACE WAMBUI'),
            receiptNo: Value(code),
            dedupeKey: Value(code),
            messageHash: Value('hash-$code'),
            balanceAfterMinor: Value(wallet),
          ),
        );
    await fromPersonal.move(id, _stall.id);
    return id;
  }

  /// A message read in [db] on [account].
  Future<int> message(
    AppDatabase db,
    int account,
    int amount, {
    required bool inflow,
    int minutes = 2,
  }) => db
      .into(db.transactions)
      .insert(
        TransactionsCompanion.insert(
          accountId: account,
          occurredAt: now.add(Duration(minutes: minutes)),
          amountMinor: amount,
          direction: inflow
              ? TransactionDirection.inflow
              : TransactionDirection.outflow,
          kind: const Value(TransactionKind.bank),
          source: TransactionSource.sms,
        ),
      );

  Future<int?> categoryOf(AppDatabase db, int id) async => (await (db.select(
    db.transactions,
  )..where((t) => t.id.equals(id))).getSingle()).categoryOverrideId;

  group('Put money in', () {
    test('from your M-Pesa, staying on it: both sides at once, never a sale '
        'or spending', () async {
      await switched(
        _kes(50),
        _kes(37869),
        at: DateTime.utc(2026, 11, 20, 14),
        code: 'SKA1',
      );
      final from = (await c.read(putInSourcesProvider.future)).first;
      expect(from.label, 'Your M-Pesa');
      expect(
        await c
            .read(putMoneyInControllerProvider)
            .putMoneyIn(
              amountMinor: _kes(3000),
              from: from,
              into: PutInto.staysOnMpesa,
            ),
        isTrue,
      );
      expect((await _between(personal)).heldFor(_stall.id), _kes(3050));
      expect(
        (await _between(business)).onAccountsOf(personalSpaceId),
        _kes(3050),
      );
      expect(
        await _balance(personal, BookAccount.money(mpesa)),
        _kes(37869),
        reason: 'no money moves',
      );
      final p = await _totals(personal);
      expect(p.spendingMinor, 0, reason: 'not in Out or the Plan');
      expect(p.incomeMinor, 0);
      final b = await _totals(business);
      expect(b.incomeMinor, _kes(50), reason: 'only the sale: not income');
      expect(await _balance(business, BookAccount.ownerCapital), _kes(3000));
      final row = await (personal.select(
        personal.transactions,
      )..where((t) => t.linkId.isNotNull())).getSingle();
      expect(row.counterpartyName, _stall.name);
      expect(
        row.categoryOverrideId,
        await ensureCategory(personal, putIntoBusinessSeed),
      );
      await _sound(personal);
      await _sound(business);
    });

    test('from Equity bank into Business bank: each side waits for its own '
        'message and pairs with it', () async {
      final from = (await c.read(putInSourcesProvider.future))
          .firstWhere((s) => s.source == PutInSource.bank);
      expect(from.label, 'Equity bank');
      await c
          .read(putMoneyInControllerProvider)
          .putMoneyIn(
            amountMinor: _kes(3000),
            from: from,
            into: PutInto.businessBank,
          );
      expect(await business.select(business.transactions).get(), isEmpty);
      expect(await personal.select(personal.transactions).get(), isEmpty);

      final out = await message(personal, equity, _kes(3000), inflow: false);
      final into = await message(business, kcb, _kes(3000), inflow: true);
      expect(await c.read(payYourselfControllerProvider).matchInPersonal(), 1);
      await c.read(salesControllerProvider).matchWaiting();

      expect(
        await categoryOf(personal, out),
        await ensureCategory(personal, putIntoBusinessSeed),
      );
      expect(
        await categoryOf(business, into),
        await ensureCategory(business, ownerCapitalSeed),
      );
      expect(await _balance(personal, BookAccount.money(equity)), _kes(17000));
      expect(await _balance(business, BookAccount.money(kcb)), _kes(13000));
      expect((await _totals(personal)).spendingMinor, 0);
      expect((await _totals(business)).incomeMinor, 0);
      await _sound(personal);
      await _sound(business);
    });

    test('from your cash into Business cash: both sides at once', () async {
      final from = (await c.read(putInSourcesProvider.future))
          .firstWhere((s) => s.source == PutInSource.cash);
      await c
          .read(putMoneyInControllerProvider)
          .putMoneyIn(
            amountMinor: _kes(1000),
            from: from,
            into: PutInto.businessCash,
          );
      expect((await _totals(personal)).spendingMinor, 0);
      expect((await _totals(business)).incomeMinor, 0);
      expect(await _balance(business, BookAccount.ownerCapital), _kes(1000));
      await _sound(personal);
      await _sound(business);
    });

    test('"Into" offers Stays on your M-Pesa only from your M-Pesa', () {
      expect(putIntoFor(PutInSource.mpesa), PutInto.values);
      expect(putIntoFor(PutInSource.bank), [
        PutInto.businessCash,
        PutInto.businessBank,
      ]);
    });
  });

  group('Pay yourself by bank: where it lands', () {
    test('Your M-Pesa: only the M-Pesa message is matched, counted once, '
        'and it is chosen first next time', () async {
      await c
          .read(payYourselfControllerProvider)
          .payYourself(
            amountMinor: _kes(2500),
            method: SalePaymentMethod.bank,
            as: PersonalPayAs.salary,
            lands: LandsOn(mpesa),
          );
      // Nothing shows in Personal until the message comes.
      expect(await personal.select(personal.transactions).get(), isEmpty);
      // The same amount into Equity is not the pay.
      final elsewhere = await message(
        personal,
        equity,
        _kes(2500),
        inflow: true,
      );
      final mine = await message(personal, mpesa, _kes(2500), inflow: true);
      expect(await c.read(payYourselfControllerProvider).matchInPersonal(), 1);
      expect(await categoryOf(personal, elsewhere), isNull);
      expect(
        await categoryOf(personal, mine),
        await ensureCategory(personal, payFromBusinessSeed),
      );
      expect(
        await lastLanding(DriftAppSettingsRepository(personal)),
        LandsOn(mpesa),
      );
      final landings = await c.read(payLandingsProvider.future);
      expect(landings.options.map((o) => o.label), [
        'Your M-Pesa',
        'Equity bank',
        'Not tracked here',
      ]);
      expect(landings.last, LandsOn(mpesa));
    });

    test('Not tracked here: Personal counts the pay at once, and none of '
        'its accounts goes up', () async {
      await c
          .read(payYourselfControllerProvider)
          .payYourself(
            amountMinor: _kes(2500),
            method: SalePaymentMethod.bank,
            as: PersonalPayAs.salary,
            lands: const LandsUntracked(),
          );
      expect((await _totals(personal)).incomeMinor, _kes(2500));
      expect(await _balance(personal, BookAccount.money(mpesa)), _kes(37819));
      expect(await _balance(personal, BookAccount.money(equity)), _kes(20000));
      expect(
        await DriftAppSettingsRepository(personal).readJson(expectedPayKey),
        isNull,
        reason: 'nothing waits in Personal',
      );
      await _sound(personal);
    });
  });

  group('restore check', () {
    setUp(() async {
      await switched(
        _kes(650),
        _kes(38469),
        at: DateTime.utc(2026, 11, 18, 14, 6),
        code: 'SKL4AB12CD',
      );
      await switched(
        _kes(400),
        _kes(38069),
        at: DateTime.utc(2026, 11, 19, 15, 20),
        code: 'SKM2CD34EF',
        inflow: false,
      );
      await switched(
        _kes(1200),
        _kes(39269),
        at: DateTime.utc(2026, 11, 20, 6, 15),
        code: 'SKN7GH56JK',
      );
    });

    /// The stall restored from a backup made before the three.
    Future<void> stallRestored() async {
      await business.delete(business.transactions).go();
      await RestoreCheck.mark(business, DateTime.utc(2026, 11, 14));
    }

    test('the stall restored: 3 payments on one side only, made again with '
        'money in as Sales and money out not yet sorted', () async {
      await stallRestored();
      final sided = await c.read(oneSidedProvider.future);
      expect(sided, isNotNull);
      expect(sided!.payments, hasLength(3));
      expect(sided.heldMinor, _kes(1450));
      expect(sided.lineName, 'M-Pesa');
      expect(sided.payments.map((p) => p.code), [
        'SKL4AB12CD',
        'SKM2CD34EF',
        'SKN7GH56JK',
      ]);

      await c
          .read(oneSidedControllerProvider)
          .answer(sided, OneSidedAnswer.makeAgain);
      final rows = await (business.select(
        business.transactions,
      )..orderBy([(t) => OrderingTerm.asc(t.occurredAt)])).get();
      final sales = await ensureCategory(business, salesSeed);
      expect(rows.map((r) => r.categoryOverrideId), [sales, null, sales]);
      expect(rows.map((r) => r.counterpartyName), everyElement(isNull));
      expect(
        (await _between(business)).onAccountsOf(personalSpaceId),
        _kes(1450),
      );
      expect((await _between(personal)).heldFor(_stall.id), _kes(1450));
      expect(await _balance(personal, BookAccount.money(mpesa)), _kes(39269));
      final b = await _totals(business);
      expect(b.incomeMinor, _kes(1850));
      expect(b.spendingMinor, _kes(400));
      expect((await _totals(personal)).moneyInMinor, 0);
      expect(await c.read(oneSidedProvider.future), isNull);
      expect(await RestoreCheck.read(business), isNull, reason: 'done');
      await _sound(personal);
      await _sound(business);
    });

    test('"Leave them apart": nothing changes and the card goes', () async {
      await stallRestored();
      final sided = (await c.read(oneSidedProvider.future))!;
      await c
          .read(oneSidedControllerProvider)
          .answer(sided, OneSidedAnswer.leaveApart);
      expect(await c.read(oneSidedProvider.future), isNull);
      expect(await business.select(business.transactions).get(), isEmpty);
      expect((await _between(personal)).heldFor(_stall.id), _kes(1450));
    });

    test('"They were mine": Personal\'s own payments again, the stall\'s '
        'part undone', () async {
      await stallRestored();
      final sided = (await c.read(oneSidedProvider.future))!;
      await c
          .read(oneSidedControllerProvider)
          .answer(sided, OneSidedAnswer.wereMine);
      expect(await personal.select(personal.balanceRecords).get(), isEmpty);
      final rows = await personal.select(personal.transactions).get();
      expect(rows, hasLength(3));
      expect(rows.map((r) => r.accountId), everyElement(mpesa));
      expect((await _between(personal)).heldFor(_stall.id), 0);
      expect(await _balance(personal, BookAccount.money(mpesa)), _kes(39269));
      expect(await c.read(oneSidedProvider.future), isNull);
      expect(await JournalRepository(personal).unbalanced(), isEmpty);
      // Money in from someone not named yet waits to be named, as any
      // payment in Personal does; nothing else is unexplained.
      expect(await _balance(personal, BookAccount.notYetSorted), _kes(1850));
    });

    test('Personal restored: the stall still has them, so Personal\'s '
        'records are made again in full, with no row added', () async {
      await personal.delete(personal.balanceRecords).go();
      await RestoreCheck.mark(personal, DateTime.utc(2026, 11, 14));
      final missing = await missingInPersonal(
        personal: personal,
        business: business,
      );
      expect(missing, hasLength(3));
      expect(missing.first.categoryName, 'Sales');
      expect(missing.first.name, 'GRACE WAMBUI');
      await remakeInPersonal(
        personal: personal,
        businessId: _stall.id,
        businessName: _stall.name,
        payments: missing,
      );
      expect(
        await personal.select(personal.balanceRecords).get(),
        hasLength(3),
      );
      expect(await personal.select(personal.transactions).get(), isEmpty);
      expect((await _between(personal)).heldFor(_stall.id), _kes(1450));
      expect(
        (await _between(business)).onAccountsOf(personalSpaceId),
        _kes(1450),
      );
      expect(
        await missingInPersonal(personal: personal, business: business),
        isEmpty,
      );
      expect(await JournalRepository(personal).unbalanced(), isEmpty);
    });
  });

  group('Clear data on the stall', () {
    setUp(() async {
      await switched(
        _kes(650),
        _kes(38469),
        at: DateTime.utc(2026, 11, 18, 14, 6),
        code: 'SKL4AB12CD',
      );
    });

    test('"Keep it apart": the cleared stall keeps On your M-Pesa 650 as '
        'its opening amount, so both sides agree', () async {
      await c
          .read(spaceManagerProvider)
          .clear(_stall, keep: false, held: HeldOnClear.apart);
      expect(await business.select(business.transactions).get(), isEmpty);
      await JournalRepository(business).sync();
      expect(
        (await _between(business)).onAccountsOf(personalSpaceId),
        _kes(650),
      );
      expect((await _between(personal)).heldFor(_stall.id), _kes(650));
      expect((await _totals(business)).incomeMinor, 0);
      await _sound(business);
      await _sound(personal);
    });

    test(
      '"It is mine now": filed as pay; nothing held for the stall',
      () async {
        await c
            .read(spaceManagerProvider)
            .clear(_stall, keep: false, held: HeldOnClear.mine);
        expect((await _between(personal)).heldFor(_stall.id), 0);
        expect((await _totals(personal)).incomeMinor, _kes(650));
        await JournalRepository(business).sync();
        expect((await _between(business)).onAccountsOf(personalSpaceId), 0);
        await _sound(personal);
        await _sound(business);
      },
    );

    test(
      'a date range asks only when the range holds the stall\'s money',
      () async {
        expect(
          await ownersPartInRange(
            business,
            DateTime.utc(2026, 11),
            DateTime.utc(2026, 11, 10),
          ),
          0,
        );
        expect(
          await ownersPartInRange(
            business,
            DateTime.utc(2026, 11, 18),
            DateTime.utc(2026, 11, 19),
          ),
          _kes(650),
        );
        await c
            .read(spaceManagerProvider)
            .clear(
              _stall,
              keep: false,
              held: HeldOnClear.apart,
              from: DateTime.utc(2026, 11, 18),
              to: DateTime.utc(2026, 11, 19),
            );
        await JournalRepository(business).sync();
        expect(
          (await _between(business)).onAccountsOf(personalSpaceId),
          _kes(650),
        );
        await _sound(business);
      },
    );
  });
}

/// What clearing [from] to [to] would take off the stall's money on the
/// owner's accounts.
Future<int> ownersPartInRange(
  AppDatabase business,
  DateTime from,
  DateTime to,
) async => (await ownersPartIn(
  business,
  from: from,
  to: to,
)).values.fold<int>(0, (sum, v) => sum + v);
