// Money between the owner and the business (decision 0027, section 6),
// through the app's own code: Pay yourself on a shared line within the
// agreed limit, and "This was for me" on the business's own account, with
// the purchase in Personal as spending only. Regression test for audit B's
// B6 (f07). Made-up data only.
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
import 'package:pesaclarity/src/data/repositories/space_move_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/domain/books/book_account.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_totals.dart';
import 'package:pesaclarity/src/domain/spaces/money_between_spaces.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/domain/spaces/space_categories.dart';
import 'package:pesaclarity/src/features/sales/application/pay_yourself.dart';
import 'package:pesaclarity/src/features/spaces/application/spaces_providers.dart';

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

void main() {
  late AppDatabase personal;
  late AppDatabase business;
  late ProviderContainer c;
  late int mpesa;
  late int kcb;
  late DriftSpaceMoveRepository fromPersonal;
  final now = DateTime.utc(2026, 11, 21, 10, 5);

  setUp(() async {
    personal = openTestDatabase();
    business = openTestDatabase();
    await business.becomeSpace(SpaceKind.business);
    c = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(business),
        personalDatabaseProvider.overrideWithValue(personal),
        mainDatabaseProvider.overrideWithValue(personal),
        clockProvider.overrideWithValue(() => now),
        activeSpaceProvider.overrideWithValue(_stall),
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
  Future<void> switched(int amount, int wallet, {bool inflow = true}) async {
    final id = await personal
        .into(personal.transactions)
        .insert(
          TransactionsCompanion.insert(
            accountId: mpesa,
            occurredAt: DateTime.utc(2026, 11, 20, 14, amount % 60),
            amountMinor: amount,
            direction: inflow
                ? TransactionDirection.inflow
                : TransactionDirection.outflow,
            kind: Value(
              inflow ? TransactionKind.received : TransactionKind.paybill,
            ),
            source: TransactionSource.sms,
            counterpartyName: const Value('GRACE WAMBUI'),
            dedupeKey: Value('S$amount'),
            balanceAfterMinor: Value(wallet),
          ),
        );
    await fromPersonal.move(id, _stall.id);
  }

  group('Pay yourself on the shared line (section 3, step 3)', () {
    late int owners;

    setUp(() async {
      await switched(_kes(650), _kes(38469));
      await switched(_kes(400), _kes(38069), inflow: false);
      owners = (await business.select(business.accounts).get())
          .singleWhere((a) => a.type == AccountType.ownersAccount)
          .id;
    });

    test('is recorded at once on both sides: Held for the stall 50, salary '
        '200 in Personal, Paid yourself 200, profit still 250', () async {
      final saved = await c
          .read(payYourselfControllerProvider)
          .payYourselfOnLine(
            amountMinor: _kes(200),
            ownersAccountId: owners,
            as: PersonalPayAs.salary,
            onLineMinor: _kes(250),
          );
      expect(saved, isTrue);

      expect((await _between(personal)).heldFor(_stall.id), _kes(50));
      expect(
        (await _between(business)).onAccountsOf(personalSpaceId),
        _kes(50),
      );
      expect((await _totals(personal)).incomeMinor, _kes(200));
      final books = await JournalRepository(business).read();
      expect(
        -books.balanceOf(BookAccount.ownerPay, currency: 'KES'),
        _kes(200),
      );
      expect(
        (await business.select(business.accounts).get()).map((a) => a.type),
        isNot(contains(AccountType.mpesa)),
        reason: 'the stall has no M-Pesa of its own',
      );
      final walletBooks = await JournalRepository(personal).read();
      expect(
        walletBooks.balanceOf(BookAccount.money(mpesa), currency: 'KES'),
        _kes(38069),
        reason: 'no money moves',
      );
      // Nothing waits for a message.
      expect(
        await DriftAppSettingsRepository(personal).readJson(expectedPayKey),
        isNull,
      );
      final pay = await (personal.select(
        personal.transactions,
      )..where((t) => t.linkId.isNotNull())).getSingle();
      final there = await (business.select(
        business.transactions,
      )..where((t) => t.linkId.equals(pay.linkId!))).getSingle();
      expect(there.amountMinor, pay.amountMinor);
    });

    test('takes no more than the stall has on the line', () async {
      final saved = await c
          .read(payYourselfControllerProvider)
          .payYourselfOnLine(
            amountMinor: _kes(300),
            ownersAccountId: owners,
            as: PersonalPayAs.salary,
            onLineMinor: (await _between(business)).payableFrom(owners),
          );
      expect(saved, isFalse);
      expect((await _between(personal)).heldFor(_stall.id), _kes(250));
      expect(
        payYourselfLimitError(
          amountMinor: _kes(300),
          onLineMinor: _kes(250),
          business: _stall.name,
          line: 'M-Pesa',
          money: (m) => 'KES ${m ~/ 100}',
        ),
        'The stall has KES 250 on your M-Pesa. To take more, pay from '
        'another business account.',
      );
    });

    test("audit B6: a customer's payment of the same amount is not filed "
        "as the owner's pay", () async {
      await c
          .read(payYourselfControllerProvider)
          .payYourselfOnLine(
            amountMinor: _kes(200),
            ownersAccountId: owners,
            as: PersonalPayAs.salary,
            onLineMinor: _kes(250),
          );
      final sale = await personal
          .into(personal.transactions)
          .insert(
            TransactionsCompanion.insert(
              accountId: mpesa,
              occurredAt: now.add(const Duration(minutes: 90)),
              amountMinor: _kes(200),
              direction: TransactionDirection.inflow,
              kind: const Value(TransactionKind.received),
              source: TransactionSource.sms,
              counterpartyName: const Value('TEST CUSTOMER'),
              dedupeKey: const Value('R1'),
            ),
          );
      expect(await c.read(payYourselfControllerProvider).matchInPersonal(), 0);
      final row = await (personal.select(
        personal.transactions,
      )..where((t) => t.id.equals(sale))).getSingle();
      expect(row.categoryOverrideId, isNull);
    });
  });

  group('"This was for me" (section 6)', () {
    late int lunch;

    setUp(() async {
      lunch = await business
          .into(business.transactions)
          .insert(
            TransactionsCompanion.insert(
              accountId: kcb,
              occurredAt: DateTime.utc(2026, 11, 21, 10, 5),
              amountMinor: _kes(800),
              direction: TransactionDirection.outflow,
              kind: const Value(TransactionKind.bank),
              source: TransactionSource.sms,
              counterpartyName: const Value("MAMA OLIECH'S KITCHEN"),
            ),
          );
    });

    DriftSpaceMoveRepository fromStall() => DriftSpaceMoveRepository(
      business,
      (_) async => (personal, false),
      sourceSpaceId: _stall.id,
      nameOf: (id) async => id == _stall.id ? _stall.name : 'Personal',
    );

    test('is Paid yourself in the stall and spending only in Personal, with '
        'no Personal account going down', () async {
      final food = await (personal.select(
        personal.categories,
      )..where((c) => c.key.equals('eating_out'))).getSingleOrNull();
      await fromStall().forMe(lunch, personalCategoryId: food?.id);

      final row = await (business.select(
        business.transactions,
      )..where((t) => t.id.equals(lunch))).getSingle();
      expect(
        row.categoryOverrideId,
        await ensureCategory(business, ownerPaySeed),
      );
      final books = await JournalRepository(business).read();
      expect(
        books.balanceOf(BookAccount.money(kcb), currency: 'KES'),
        _kes(9200),
      );
      expect(
        -books.balanceOf(BookAccount.ownerPay, currency: 'KES'),
        _kes(800),
      );
      expect(
        (await _totals(business)).spendingMinor,
        0,
        reason: 'never a cost',
      );

      final purchase = await (personal.select(
        personal.transactions,
      )..where((t) => t.linkId.equals(row.linkId!))).getSingle();
      final account = await (personal.select(
        personal.accounts,
      )..where((a) => a.id.equals(purchase.accountId))).getSingle();
      expect(account.type, AccountType.paidBySpace);
      expect(account.name, _stall.name);
      final totals = await _totals(personal);
      expect(totals.moneyInMinor, 0);
      expect(totals.incomeMinor, 0);
      expect(totals.spendingMinor, _kes(800));
      final personalBooks = await JournalRepository(personal).read();
      expect(
        personalBooks.balanceOf(BookAccount.money(mpesa), currency: 'KES'),
        _kes(37819),
      );
      expect(
        personalBooks.balanceOf(
          BookAccount.paidBySpace(account.id),
          currency: 'KES',
        ),
        _kes(800),
      );
    });

    test('switching the purchase to the stall is "This was for the '
        'business": the Food row goes and it becomes a cost', () async {
      await fromStall().forMe(lunch);
      final purchase = await (personal.select(
        personal.transactions,
      )..where((t) => t.linkId.isNotNull())).getSingle();
      final meals = await ensureCategory(business, stockSeed);
      await fromPersonal.move(purchase.id, _stall.id, toCategoryId: meals);

      expect(await personal.select(personal.transactions).get(), isEmpty);
      expect((await _totals(personal)).spendingMinor, 0);
      final row = await (business.select(
        business.transactions,
      )..where((t) => t.id.equals(lunch))).getSingle();
      expect(row.categoryOverrideId, meals);
      expect(row.linkId, isNull);
      final books = await JournalRepository(business).read();
      expect(-books.balanceOf(BookAccount.ownerPay, currency: 'KES'), 0);
      expect((await _totals(business)).spendingMinor, _kes(800));
      expect(
        books.balanceOf(BookAccount.money(kcb), currency: 'KES'),
        _kes(9200),
      );
    });

    test('switching the payment to Personal from the stall is the same as '
        '"This was for me"', () async {
      await fromStall().move(lunch, personalSpaceId);
      expect(await personal.select(personal.transactions).get(), hasLength(1));
      final row = await (business.select(
        business.transactions,
      )..where((t) => t.id.equals(lunch))).getSingle();
      expect(row.linkedSpaceId, personalSpaceId);
      // Doing it again changes nothing.
      await fromStall().forMe(lunch);
      expect(await personal.select(personal.transactions).get(), hasLength(1));
    });
  });
}
