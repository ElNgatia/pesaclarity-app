// Each message lands in one space: the one that reads its account, or the
// one the person moved it to. A business that read M-Pesa alongside
// Personal before each account was read in one space held every Personal
// payment too, so the two counted each one twice; the repair on update
// takes those copies out once, and reading again never brings them back.
// Made-up data only.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/data/database/space_databases.dart';
import 'package:pesaclarity/src/data/repositories/accounts_repository.dart';
import 'package:pesaclarity/src/data/repositories/app_settings_repository.dart';
import 'package:pesaclarity/src/data/repositories/balances_repair.dart';
import 'package:pesaclarity/src/data/repositories/institutions_repository.dart';
import 'package:pesaclarity/src/data/repositories/journal_repository.dart';
import 'package:pesaclarity/src/data/repositories/message_reads_repository.dart';
import 'package:pesaclarity/src/data/repositories/review_inbox_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_totals.dart';
import 'package:pesaclarity/src/domain/spaces/line_routing.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/features/accounts/domain/institution.dart';
import 'package:pesaclarity/src/features/balances/application/balances_providers.dart';
import 'package:pesaclarity/src/features/sms/application/read_again.dart';
import 'package:pesaclarity/src/features/sms/application/sms_capture_providers.dart';
import 'package:pesaclarity/src/features/sms/application/sms_ingestor.dart';
import 'package:pesaclarity/src/features/spaces/application/routing_providers.dart';
import 'package:pesaclarity/src/features/spaces/application/spaces_providers.dart';
import 'package:ujumbe/ujumbe.dart';

import '../../helpers/fake_sms_source.dart';
import '../../helpers/sms_samples.dart';
import '../../helpers/spaces_harness.dart';
import '../../helpers/test_app.dart';

const _shop = Space(
  id: 'shop1',
  name: 'Mama Njeri Shop',
  kind: SpaceKind.business,
);

SmsMessage _paid(String receipt, int shillings, int day, int balance) =>
    mpesaSms(
      '$receipt Confirmed. Ksh$shillings.00 paid to EXAMPLE GROCERS. on '
      '$day/11/26 at 1:45 PM.New M-PESA balance is Ksh$balance.00. '
      'Transaction cost, Ksh0.00.',
      DateTime.utc(2026, 11, day, 10, 45, 5),
    );

SmsMessage _received(String receipt, int day, int balance) => mpesaSms(
  '$receipt Confirmed.You have received Ksh650.00 from TEST CUSTOMER '
  '0700***002 on $day/11/26 at 11:30 AM  New M-PESA balance is '
  'Ksh$balance.00.',
  DateTime.utc(2026, 11, day, 8, 30, 5),
);

final _history = [
  _paid('TJA0000801', 1200, 1, 28800),
  _paid('TJA0000802', 350, 10, 28450),
  _received('TJA0000803', 12, 29100),
];

final _mpesa = institutionCatalogue.firstWhere((i) => i.id == 'mpesa');

void main() {
  late AppDatabase personal;
  late AppDatabase shop;
  late PhoneInbox phone;

  Future<List<String?>> receipts(AppDatabase db) async => [
    for (final t in await (db.select(
      db.transactions,
    )..orderBy([(t) => OrderingTerm.asc(t.occurredAt)])).get())
      t.receiptNo,
  ];

  Future<int> moneyIn(AppDatabase db) async => LedgerTotals.of(
    await DriftTransactionsRepository(db)
        .ledgerEntries(from: DateTime.utc(2026), to: DateTime.utc(2027)),
    from: DateTime.utc(2026),
    to: DateTime.utc(2027),
  ).moneyInMinor;

  Future<int> wallet(AppDatabase db) async {
    final mpesa = await (db.select(
      db.accounts,
    )..where((a) => a.institutionId.equals('mpesa'))).getSingle();
    final opening = (await DriftAccountsRepository(
      db,
    ).openings()).singleWhere((o) => o.id == mpesa.id);
    await JournalRepository(db).sync();
    return (await JournalRepository(
      db,
    ).read()).walletAt(opening, at: DateTime.utc(2027));
  }

  /// How a space read its accounts before each was read in one space only:
  /// every message of M-Pesa, whatever another space held.
  Future<void> readAsBefore(AppDatabase db) async {
    await DriftInstitutionsRepository(db).setSelected('mpesa', selected: true);
    await SmsIngestor(
      accounts: DriftAccountsRepository(db),
      transactions: DriftTransactionsRepository(db),
      reviewInbox: DriftReviewInboxRepository(db),
      reads: MessageReadsRepository(db),
      parse: (packs, messages) async => parseAll(packs, messages),
    ).ingest(_history, [_mpesa]);
  }

  Future<ProviderContainer> app(String open) async {
    await DriftAppSettingsRepository(personal).writeJson(
      SpacesController.settingsKey,
      spacesToJson([Space.personal, _shop]),
    );
    return twoSpaces(
      personal: personal,
      other: shop,
      sms: phone,
      clock: () => DateTime.utc(2026, 11, 20, 9),
      active: open,
    );
  }

  Future<void> openWithCapture(ProviderContainer c) async {
    final shell = c.listen(liveSmsCaptureProvider, (_, _) {});
    addTearDown(shell.close);
    await captureIsSteady(phone);
    await settle();
  }

  Future<void> switchTo(ProviderContainer c, String spaceId) async {
    await c.read(activeSpaceIdProvider.notifier).switchTo(spaceId);
    await captureIsSteady(phone);
    await settle();
  }

  /// The repair on update, as the app runs it when a space opens.
  Future<void> repair(ProviderContainer c) async {
    c.invalidate(pairHistoryOnceProvider);
    await c.read(pairHistoryOnceProvider.future);
  }

  setUp(() async {
    personal = openTestDatabase();
    shop = openTestDatabase();
    await shop.becomeSpace(SpaceKind.business);
    phone = PhoneInbox();
    addTearDown(phone.close);
    _history.forEach(phone.receive);
  });

  group('a business that read M-Pesa alongside Personal', () {
    setUp(() async {
      await readAsBefore(personal);
      await readAsBefore(shop);
    });

    test('held every Personal payment, and the repair takes them out '
        'once', () async {
      final both = ['TJA0000801', 'TJA0000802', 'TJA0000803'];
      expect(await receipts(personal), both);
      expect(await receipts(shop), both, reason: 'the leak');
      expect(
        await moneyIn(personal) + await moneyIn(shop),
        2 * 65000,
        reason: 'every payment counted twice',
      );

      final c = await app(_shop.id);
      await openWithCapture(c);
      // Each account is read in one space: M-Pesa is left to Personal and
      // shared with the shop. The copies it read stayed until the repair.
      expect(await DriftInstitutionsRepository(shop).selectedIds(), isEmpty);
      await repair(c);

      expect(await receipts(shop), isEmpty);
      expect(await moneyIn(shop), 0);
      expect(await receipts(personal), both);
      expect(await moneyIn(personal), 65000);
      expect(await wallet(personal), 2910000, reason: 'as last reported');
      expect(await JournalRepository(shop).unbalanced(), isEmpty);

      // Once only.
      expect(
        await repairSpaceLeakOnce(shop, (
          here: _shop.id,
          ids: [personalSpaceId, _shop.id],
          open: c.read(spaceDatabasesProvider).open,
        )),
        isNull,
      );

      // Reading again, in either space, brings nothing back.
      await c.read(readAgainControllerProvider.notifier).readAgain();
      await switchTo(c, personalSpaceId);
      await repair(c);
      await c.read(readAgainControllerProvider.notifier).readAgain();
      await settle();
      expect(await receipts(shop), isEmpty);
      expect(await receipts(personal), both);

      // A new payment lands in Personal only; the shop asks about it.
      phone.receive(_received('TJA0000804', 20, 29750));
      await until(() async => (await receipts(personal)).length == 4);
      await switchTo(c, _shop.id);
      expect(await receipts(shop), isEmpty);
      expect([
        for (final q
            in await c.read(sharedLineRouterProvider).pending(_shop.id))
          q.amountMinor,
      ], contains(65000));
    });

    test('keeps in the shop what the person made the shop\'s own, and '
        'takes Personal\'s copy as a move would', () async {
      final category = await shop
          .into(shop.categories)
          .insert(
            CategoriesCompanion.insert(
              name: 'Test stock',
              type: CategoryType.expense,
            ),
          );
      await (shop.update(shop.transactions)
            ..where((t) => t.receiptNo.equals('TJA0000802')))
          .write(TransactionsCompanion(categoryOverrideId: Value(category)));

      final c = await app(_shop.id);
      await openWithCapture(c);
      await repair(c);

      expect(await receipts(shop), ['TJA0000802']);
      final kept = await (shop.select(
        shop.transactions,
      )..where((t) => t.receiptNo.equals('TJA0000802'))).getSingle();
      expect(kept.categoryOverrideId, category);
      expect(kept.balanceAfterMinor, isNull, reason: "Personal's wallet");
      expect(await receipts(personal), ['TJA0000801', 'TJA0000803']);
      expect(
        (await personal.select(personal.movedTransactions).get())
            .single
            .spaceId,
        _shop.id,
      );

      await switchTo(c, personalSpaceId);
      await c.read(readAgainControllerProvider.notifier).readAgain();
      await settle();
      expect(await receipts(personal), ['TJA0000801', 'TJA0000803']);
      expect(await receipts(shop), ['TJA0000802']);
    });

    test('runs whichever comes first, the repair or the capture leaving '
        'M-Pesa to Personal', () async {
      final c = await app(_shop.id);
      // The repair before the capture: both spaces still read M-Pesa, and
      // Personal is the one that keeps it.
      await repair(c);
      expect(await receipts(shop), isEmpty);
      await openWithCapture(c);
      await c.read(readAgainControllerProvider.notifier).readAgain();
      await switchTo(c, personalSpaceId);
      await repair(c);
      await c.read(readAgainControllerProvider.notifier).readAgain();
      await settle();
      expect(await receipts(shop), isEmpty);
      expect(await receipts(personal), hasLength(3));
      expect(await DriftInstitutionsRepository(shop).selectedIds(), isEmpty);
    });
  });

  test('Only the shop, after Personal read the history: the shop reads '
      'from then on, and Personal keeps what it read', () async {
    await DriftInstitutionsRepository(personal)
        .setSelected('mpesa', selected: true);
    final c = await app(personalSpaceId);
    await openWithCapture(c);
    await until(() async => (await receipts(personal)).length == 3);

    await switchTo(c, _shop.id);
    await c
        .read(routingRulesProvider.notifier)
        .setLine(
          'mpesa',
          LineChoice.thisBusiness,
          businessId: _shop.id,
          business: c.read(institutionsRepositoryProvider),
          personal: DriftInstitutionsRepository(personal),
        );
    await captureIsSteady(phone);
    await settle();

    expect(await DriftInstitutionsRepository(shop).selectedIds(), {'mpesa'});
    expect(await receipts(shop), isEmpty, reason: 'Personal holds them');
    expect(await receipts(personal), hasLength(3));

    phone.receive(_received('TJA0000805', 20, 29750));
    await until(() async => (await receipts(shop)).isNotEmpty);
    await c.read(readAgainControllerProvider.notifier).readAgain();
    await repair(c);
    expect(await receipts(shop), ['TJA0000805']);
    expect(await receipts(personal), hasLength(3));
    expect(await moneyIn(shop) + await moneyIn(personal), 2 * 65000);
  });
}
