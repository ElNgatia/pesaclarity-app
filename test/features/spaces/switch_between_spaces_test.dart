// Switching a payment to another space (decision 0027, sections 2 and 3):
// the transaction shows only where it was switched to, on the owner's
// account there, and the space its account lives in keeps a balance
// record. Regression tests for audit A's F1 and audit B's B2 (f01) and B8
// (f11). Made-up data only, in the shapes of the M-Pesa pack's fixtures.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/repositories/accounts_repository.dart';
import 'package:pesaclarity/src/data/repositories/balance_records_repository.dart';
import 'package:pesaclarity/src/data/repositories/journal_repository.dart';
import 'package:pesaclarity/src/data/repositories/message_reads_repository.dart';
import 'package:pesaclarity/src/data/repositories/review_inbox_repository.dart';
import 'package:pesaclarity/src/data/repositories/space_move_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/domain/books/book_account.dart';
import 'package:pesaclarity/src/domain/spaces/line_routing.dart';
import 'package:pesaclarity/src/domain/spaces/money_between_spaces.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/features/accounts/domain/institution.dart';
import 'package:pesaclarity/src/features/sms/application/sms_ingestor.dart';
import 'package:pesaclarity/src/features/spaces/application/business_setup_providers.dart';
import 'package:pesaclarity/src/features/spaces/application/routing_providers.dart';
import 'package:ujumbe/ujumbe.dart' show SmsMessage;

import '../../helpers/spaces_harness.dart';
import '../../helpers/test_app.dart';

const _shop = 'shop1';

int _kes(int shillings) => shillings * 100;

String _sh(int minor) => (minor / 100).toStringAsFixed(2);

final _mpesa = institutionCatalogue.singleWhere((i) => i.id == 'mpesa');

/// Reads M-Pesa [body], received at [at], into [db].
Future<void> _read(AppDatabase db, String body, DateTime at) => SmsIngestor(
  accounts: DriftAccountsRepository(db),
  transactions: DriftTransactionsRepository(db),
  reviewInbox: DriftReviewInboxRepository(db),
  reads: MessageReadsRepository(db),
  parse: (packs, messages) async => parseAll(packs, messages),
).ingest([SmsMessage(sender: 'MPESA', body: body, receivedAt: at)], [_mpesa]);

/// M-Pesa's message for money received, printing the wallet's balance.
Future<void> _received(
  AppDatabase db,
  String receipt,
  String amount,
  String who,
  String balance,
  DateTime at,
) => _read(
  db,
  '$receipt Confirmed.You have received Ksh$amount from $who on '
  '${at.day}/${at.month}/26 at 10:00 AM  New M-PESA balance is '
  'Ksh$balance.',
  at,
);

/// M-Pesa's message for a payment to a till, printing the wallet's balance.
Future<void> _paid(
  AppDatabase db,
  String receipt,
  String amount,
  String who,
  String balance,
  DateTime at,
) => _read(
  db,
  '$receipt Confirmed. Ksh$amount paid to $who. on ${at.day}/${at.month}/26 '
  'at 10:00 AM.New M-PESA balance is Ksh$balance. Transaction cost, '
  'Ksh0.00. Amount you can transact within the day is 499,000.00.',
  at,
);

/// What [db]'s journal says its accounts are worth (wallets less Fuliza
/// owed), as Home and Balances read it.
Future<int> _held(AppDatabase db) async {
  final accounts = await DriftAccountsRepository(db).openings();
  final journal = await JournalRepository(db).read();
  return journal.totalHeldAt(
    accounts,
    at: DateTime.utc(2100),
    where: (_) => true,
  );
}

/// [db]'s money between spaces, from its journal.
Future<MoneyBetweenSpaces> _between(AppDatabase db) async =>
    MoneyBetweenSpaces.of(
      await betweenSpacesAccounts(db),
      await JournalRepository(db).read(),
    );

/// What [db]'s reported balances leave unexplained, by account.
Future<Map<int, int>> _gaps(AppDatabase db) => JournalRepository(db).openGaps();

/// Fuliza owed across [db]'s accounts, as its journal has it.
Future<int> _fulizaOwed(AppDatabase db) async {
  final accounts = await DriftAccountsRepository(db).openings();
  final journal = await JournalRepository(db).read();
  return accounts.fold<int>(
    0,
    (sum, a) => sum + journal.fulizaOwedAt(a, at: DateTime.utc(2100)),
  );
}

/// The router for an M-Pesa line Personal shares with the shop.
SharedLineRouter _router(
  AppDatabase personal,
  AppDatabase business,
  DateTime Function() now,
) {
  var rules = const RoutingRules(sharedLines: {'mpesa': _shop});
  return SharedLineRouter(
    personal: personal,
    moveFromPersonal: DriftSpaceMoveRepository(
      personal,
      (_) async => (business, false),
      nameOf: (id) async => id == _shop ? 'Test Shop' : 'Personal',
    ),
    rules: () async => rules,
    remember: (key, spaceId) async => rules = rules.withPerson(key, spaceId),
    now: now,
  );
}

/// Answers the question about [name]'s payment "Business sale" (or
/// "Business cost"), without "Always do this".
Future<void> _forTheBusiness(SharedLineRouter router, String name) async {
  final question = (await router.pending(_shop))
      .singleWhere((q) => q.name == name);
  await router.answer(
    question,
    businessId: _shop,
    forBusiness: true,
    always: false,
  );
}

Future<AppDatabase> _businessDatabase() async {
  final db = openTestDatabase();
  await db.becomeSpace(SpaceKind.business);
  return db;
}

void main() {
  // Audit A, F1: "Business sale" for KES 650 gave the business the owner's
  // whole M-Pesa balance. Audit B, B8: and it was no sale.
  group('a sale answered for the business', () {
    final now = DateTime.utc(2026, 11, 20, 9);
    late AppDatabase personal;
    late AppDatabase business;
    late SharedLineRouter router;

    setUp(() async {
      personal = openTestDatabase();
      business = await _businessDatabase();
      router = _router(personal, business, () => now);
      await _paid(
        personal,
        'TJA0000101',
        '500.00',
        'EXAMPLE GROCERS',
        '37,819.00',
        DateTime.utc(2026, 11, 17, 6),
      );
      // A customer pays the shop KES 650 on the shared line.
      await _received(
        personal,
        'TJA0000102',
        '650.00',
        'GRACE WAMBUI 0700***002',
        '38,469.00',
        DateTime.utc(2026, 11, 18, 7),
      );
      await _read(
        personal,
        'TJA0000103 Confirmed. Ksh1,000.00 sent to JANE DOE 0700***001 on '
        '19/11/26 at 9:15 AM. New M-PESA balance is Ksh37,454.00. '
        'Transaction cost, Ksh15.00. Amount you can transact within the '
        'day is 498,500.00.',
        DateTime.utc(2026, 11, 19, 6, 15),
      );
      expect(await _held(personal), _kes(37454));
    });

    test("gives the business KES 650 on the owner's account, as a sale, "
        "not the owner's whole M-Pesa balance", () async {
      await _forTheBusiness(router, 'GRACE WAMBUI');

      final moved = await business.select(business.transactions).getSingle();
      expect(moved.amountMinor, _kes(650));
      expect(moved.balanceAfterMinor, isNull);
      expect(moved.counterpartyName, 'GRACE WAMBUI');
      final sales = await (business.select(
        business.categories,
      )..where((c) => c.key.equals('sales'))).getSingle();
      expect(moved.categoryOverrideId, sales.id, reason: 'B8: a sale');
      final account = await business.select(business.accounts).getSingle();
      expect(account.type, AccountType.ownersAccount);
      expect(account.name, 'Your M-Pesa');
      // The business has no M-Pesa account of its own.
      expect(await _held(business), 0);
      final between = await _between(business);
      expect(
        between.onAccountsOf(personalSpaceId),
        _kes(650),
        reason:
            'the business was given one KES 650.00 sale; it shows KES '
            '${_sh(between.onAccountsOf(personalSpaceId))}',
      );
      final income = await JournalRepository(business).read();
      expect(
        income.balanceOf(
          BookAccount.category(sales.id, income: true),
          currency: 'KES',
        ),
        _kes(650),
      );
    });

    test('leaves Personal whole: what the wallet holds, KES 650 of it the '
        "shop's, with no gap and no row", () async {
      await _forTheBusiness(router, 'GRACE WAMBUI');

      expect(await _held(personal), _kes(37454));
      expect((await _between(personal)).heldFor(_shop), _kes(650));
      expect(await _gaps(personal), isEmpty, reason: 'F1: no gap');
      final rows = await DriftTransactionsRepository(personal)
          .ledgerEntries(from: DateTime.utc(2026), to: DateTime.utc(2027));
      expect(
        rows.map((e) => e.counterpartyName),
        isNot(contains('GRACE WAMBUI')),
      );
      expect(
        await personal.select(personal.balanceRecords).get(),
        hasLength(1),
      );
    });

    test('the two spaces together hold what the one wallet holds', () async {
      await _forTheBusiness(router, 'GRACE WAMBUI');
      final p = await _held(personal) - (await _between(personal)).notOwnMinor;
      final b =
          await _held(business) + (await _between(business)).ownersMoneyMinor;
      expect(p + b, _kes(37454), reason: 'Personal ${_sh(p)}, shop ${_sh(b)}');
    });

    test('reading the message again does not bring it back', () async {
      await _forTheBusiness(router, 'GRACE WAMBUI');
      await _received(
        personal,
        'TJA0000102',
        '650.00',
        'GRACE WAMBUI 0700***002',
        '38,469.00',
        DateTime.utc(2026, 11, 18, 7),
      );
      expect(await personal.select(personal.transactions).get(), hasLength(2));
      expect(await _held(personal), _kes(37454));
    });

    test('switching it back puts it in Personal only, and Held for back '
        'as it was; it can be switched again', () async {
      await _forTheBusiness(router, 'GRACE WAMBUI');
      final there = await business.select(business.transactions).getSingle();
      final back = DriftSpaceMoveRepository(
        business,
        (_) async => (personal, false),
        sourceSpaceId: _shop,
      );
      await back.move(there.id, personalSpaceId);

      expect(await business.select(business.transactions).get(), isEmpty);
      expect(await personal.select(personal.balanceRecords).get(), isEmpty);
      final sale = await (personal.select(
        personal.transactions,
      )..where((t) => t.receiptNo.equals('TJA0000102'))).getSingle();
      expect(sale.balanceAfterMinor, _kes(38469));
      expect(sale.counterpartyName, 'GRACE WAMBUI');
      expect(sale.messageHash, isNotNull);
      expect((await _between(personal)).heldFor(_shop), 0);
      expect((await _between(business)).onAccountsOf(personalSpaceId), 0);
      expect(await _held(personal), _kes(37454));
      expect(await _gaps(personal), isEmpty);

      // And to the shop again.
      await DriftSpaceMoveRepository(
        personal,
        (_) async => (business, false),
      ).move(sale.id, _shop);
      expect(await business.select(business.transactions).get(), hasLength(1));
      expect((await _between(personal)).heldFor(_shop), _kes(650));
      expect(await _gaps(personal), isEmpty);
    });

    test('switching twice changes nothing more', () async {
      await _forTheBusiness(router, 'GRACE WAMBUI');
      final record = await personal.select(personal.balanceRecords).getSingle();
      // A switch that ran half-way and is run again finds both sides done.
      final mover = DriftSpaceMoveRepository(
        personal,
        (_) async => (business, false),
      );
      final id = await personal
          .into(personal.transactions)
          .insert(
            TransactionsCompanion.insert(
              accountId: record.accountId,
              occurredAt: record.occurredAt,
              amountMinor: record.amountMinor,
              direction: record.direction,
              source: TransactionSource.sms,
              dedupeKey: Value(record.dedupeKey),
            ),
          );
      await mover.move(id, _shop);
      expect(await business.select(business.transactions).get(), hasLength(1));
      expect(
        await personal.select(personal.balanceRecords).get(),
        hasLength(1),
      );
    });
  });

  // Audit B, B2: with the wallet's balance carried in, the business's
  // M-Pesa could not be put right. Now it has none of its own.
  test('Start your records offers no M-Pesa balance from the owner\'s '
      'wallet', () async {
    final personal = openTestDatabase();
    final business = await _businessDatabase();
    final now = DateTime.utc(2026, 11, 2, 12);
    final router = _router(personal, business, () => now);
    final c = twoSpaces(
      personal: personal,
      other: business,
      clock: () => now,
      active: _shop,
    );
    await _received(
      personal,
      'TJB0000101',
      '650.00',
      'GRACE WAMBUI 0700***002',
      '38,469.00',
      DateTime.utc(2026, 11, 2, 7),
    );
    await _forTheBusiness(router, 'GRACE WAMBUI');

    final lines = await c.read(openingLinesProvider.future);
    expect(lines.where((l) => l.suggestedMinor == _kes(38469)), isEmpty);
    expect(lines.where((l) => l.type == AccountType.ownersAccount), isEmpty);
    expect((await _between(business)).onAccountsOf(personalSpaceId), _kes(650));
  });

  test('a cost that empties the wallet is no Fuliza: the owner has put in '
      'the rest', () async {
    final personal = openTestDatabase();
    final business = await _businessDatabase();
    final now = DateTime.utc(2026, 11, 20, 9);
    final router = _router(personal, business, () => now);
    // A customer pays KES 650 (the wallet then holds KES 700), a friend
    // sends the owner KES 300 (KES 1,000), and the owner pays a supplier
    // KES 1,000 from the line, which empties it. No Fuliza anywhere.
    await _received(
      personal,
      'TJB0000201',
      '650.00',
      'GRACE WAMBUI 0700***002',
      '700.00',
      DateTime.utc(2026, 11, 18, 7),
    );
    await _received(
      personal,
      'TJB0000202',
      '300.00',
      'JOHN KAMAU 0700***005',
      '1,000.00',
      DateTime.utc(2026, 11, 18, 8),
    );
    await _paid(
      personal,
      'TJB0000203',
      '1,000.00',
      'EXAMPLE WHOLESALERS',
      '0.00',
      DateTime.utc(2026, 11, 18, 9),
    );
    expect(await _fulizaOwed(personal), 0);

    await _forTheBusiness(router, 'GRACE WAMBUI');
    await _forTheBusiness(router, 'EXAMPLE WHOLESALERS');

    expect(await _fulizaOwed(business), 0);
    expect(await _fulizaOwed(personal), 0);
    expect(await _held(personal), 0, reason: 'the wallet is empty');
    expect(await _gaps(personal), isEmpty);
    // The stall spent KES 350 more than it had on the line.
    expect((await _between(personal)).heldFor(_shop), -_kes(350));
    expect((await _between(business)).putInMinor, _kes(350));
    expect((await _between(business)).ownersMoneyMinor, 0);
  });
}
