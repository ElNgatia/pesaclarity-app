import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/repositories/accounts_repository.dart';
import 'package:pesaclarity/src/data/repositories/balances_repair.dart';
import 'package:pesaclarity/src/data/repositories/message_reads_repository.dart';
import 'package:pesaclarity/src/data/repositories/review_inbox_repository.dart';
import 'package:pesaclarity/src/data/repositories/savings_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/domain/accounts/mpesa_family.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_entry.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_role.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_totals.dart';
import 'package:pesaclarity/src/domain/savings/savings_product.dart';
import 'package:pesaclarity/src/features/accounts/domain/institution.dart';
import 'package:pesaclarity/src/features/sms/application/sms_ingestor.dart';
import 'package:ujumbe/ujumbe.dart';

import '../../helpers/test_app.dart';

// The M-Pesa family of accounts (decision 0026) from messages. Synthetic
// messages in the shape of the packs' fixtures: the receipts, amounts,
// times, names and numbers are invented.

final _mpesa = institutionCatalogue.singleWhere((i) => i.id == 'mpesa');
final _etica = institutionCatalogue.singleWhere((i) => i.id == 'etica');

/// A UTC instant for a Nairobi wall-clock time in November 2026.
DateTime _eat(int day, int hour, [int minute = 0]) =>
    DateTime.utc(2026, 11, day, hour - 3, minute);

SmsMessage _sms(String body, DateTime at, {String sender = 'MPESA'}) =>
    SmsMessage(
      sender: sender,
      body: body,
      receivedAt: at.add(const Duration(seconds: 5)),
    );

final _ziidiIn = _sms(
  'TJA0000030 Confirmed. Ksh1,000.00 sent to ZIIDI on 12/11/26 at 2:30 PM '
  'New M-PESA balance is Ksh50.00. Transaction cost, Ksh0.00.',
  _eat(12, 14, 30),
);
final _ziidiOut = _sms(
  'TJA0000031 Confirmed.You have received Ksh600.00 from ZIIDI on 13/11/26 '
  '5:03 PM. New M-PESA balance is Ksh650.00.',
  _eat(13, 17, 3),
);
final _shwariIn = _sms(
  'TJA0000016 Confirmed.Ksh500.00 transferred to M-Shwari account on '
  '26/10/26 at 4:00 PM. M-PESA balance is Ksh247.50 .New M-Shwari saving '
  'account balance is Ksh1,500.00. Transaction cost Ksh.0.00',
  DateTime.utc(2026, 10, 26, 13),
);
final _shwariOut = _sms(
  'TJA0000017 Confirmed.Ksh200.00 transferred from M-Shwari account on '
  '26/10/26 at 4:10 PM. M-Shwari balance is Ksh1,300.00 .M-PESA balance is '
  'Ksh447.50 .Transaction cost Ksh.0.00',
  DateTime.utc(2026, 10, 26, 13, 10),
);
final _eticaIn = _sms(
  'TJA0000020 Confirmed. Ksh1,000.00 sent to ETICA CAPITAL LTD for account '
  '000000M on 10/11/26 at 9:00 AM New M-PESA balance is Ksh900.50. '
  'Transaction cost, Ksh0.00.',
  _eat(10, 9),
);
final _eticaBack = _sms(
  'TJA0000035 Confirmed.You have received Ksh400.00 from ETICA CAPITAL LTD '
  'on 14/11/26 at 11:10 AM New M-PESA balance is Ksh1,500.50.',
  _eat(14, 11, 10),
);
final _eticaNotice = _sms(
  'Dear esteemed client,\nYour payment of KES 400.00 to 0700000000 - JANE '
  'WANJIRU DOE  from account 000000M (EMMF - KES) has been processed '
  'successfully. Transaction ref: TJA0000035',
  _eat(14, 11, 11),
  sender: 'ETICALTD',
);
final _pochi = _sms(
  'TJA0000039 Confirmed.You have received Ksh200.00 from JOHN DOE '
  '0711***000 on 15/11/26 at 8:40 AM New Pochi balance is Ksh1,200.00.',
  _eat(15, 8, 40),
);
final _till = _sms(
  'TJA0000040 Confirmed. Ksh350.00 paid to EXAMPLE GROCERS. on 15/11/26 at '
  '9:00 AM.New M-PESA balance is Ksh1,150.50. Transaction cost, Ksh0.00.',
  _eat(15, 9),
);

void main() {
  late AppDatabase db;
  late DriftTransactionsRepository transactions;
  late DriftSavingsRepository savings;
  late SmsIngestor ingestor;

  setUp(() {
    db = openTestDatabase();
    transactions = DriftTransactionsRepository(db);
    savings = DriftSavingsRepository(db);
    addTearDown(savings.dispose);
    ingestor = SmsIngestor(
      accounts: DriftAccountsRepository(db),
      transactions: transactions,
      reviewInbox: DriftReviewInboxRepository(
        db,
        clock: () => DateTime.utc(2026, 11, 21),
      ),
      reads: MessageReadsRepository(db),
      parse: (packs, messages) async => parseAll(packs, messages),
    );
  });

  Future<List<Account>> accounts() =>
      (db.select(db.accounts)..orderBy([(a) => OrderingTerm.asc(a.id)])).get();

  Future<Account> wallet() async =>
      (await accounts()).singleWhere((a) => a.type == AccountType.mpesa);

  Future<Account> productAccount(String product) async =>
      (await accounts()).singleWhere((a) => a.product == product);

  Future<List<TransactionRecord>> rows({int? accountId}) =>
      (db.select(db.transactions)
            ..where(
              (t) => accountId == null
                  ? const Constant(true)
                  : t.accountId.equals(accountId),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.occurredAt),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .get();

  Future<List<LedgerEntry>> entries() => transactions.ledgerEntries(
    from: DateTime.utc(2026),
    to: DateTime.utc(2027),
  );

  Future<LedgerRole> roleFor(String receipt, {int? accountId}) async {
    final id = (await rows(accountId: accountId))
        .firstWhere((r) => r.receiptNo == receipt)
        .id;
    return roleOf((await entries()).singleWhere((e) => e.id == id));
  }

  Future<LedgerTotals> totals() async => LedgerTotals.of(
    await entries(),
    from: DateTime.utc(2026),
    to: DateTime.utc(2027),
    currency: 'KES',
  );

  group('Ziidi', () {
    test('is an account of its own from its first message, in the M-Pesa '
        'family, and money moved is an own transfer', () async {
      await ingestor.ingest([_ziidiIn, _ziidiOut, _till], [_mpesa]);
      final ziidiAccount = await productAccount('ziidi');
      final mpesa = await wallet();
      expect(ziidiAccount.name, 'Ziidi');
      expect(ziidiAccount.type, AccountType.moneyMarket);
      expect(ziidiAccount.familyOf, mpesa.id);
      expect(await roleFor('TJA0000030'), LedgerRole.ownTransfer);
      expect(await roleFor('TJA0000031'), LedgerRole.ownTransfer);
      expect(await roleFor('TJA0000040'), LedgerRole.spending);
      final sums = await totals();
      expect(sums.incomeMinor, 0);
      expect(sums.spendingMinor, 35000);
      // No message prints its value: the money in and out.
      final summary = (await savings.account(ziidiAccount.id))!;
      expect(summary.balanceMinor, 40000);
      expect(summary.pockets, hasLength(1));
      // Not asked about, as Chumz is.
      expect(await savings.prompt(), isNull);
    });

    test('a balance the person types is its value; the rest is returns, '
        'income under Interest', () async {
      await ingestor.ingest([_ziidiIn, _ziidiOut], [_mpesa]);
      final id = (await productAccount('ziidi')).id;
      final pocket = (await savings.account(id))!.pockets.single;
      await savings.updateBalances(
        id,
        balanceByPocket: {pocket.id: 40600},
        at: _eat(20, 9),
      );
      final summary = (await savings.account(id))!;
      expect(summary.balanceMinor, 40600);
      expect(summary.interestMinor, 600);
      final interest = (await rows(accountId: id))
          .singleWhere((r) => r.counterpartyName == 'Ziidi returns');
      expect(interest.amountMinor, 600);
      expect((await totals()).incomeMinor, 600);
    });
  });

  group('M-Shwari', () {
    test("M-Pesa's message sets its balance", () async {
      await ingestor.ingest([_shwariIn, _shwariOut], [_mpesa]);
      final shwari = await productAccount('mshwari');
      expect(shwari.name, 'M-Shwari');
      expect(shwari.familyOf, (await wallet()).id);
      expect(await roleFor('TJA0000016'), LedgerRole.ownTransfer);
      expect(await roleFor('TJA0000017'), LedgerRole.ownTransfer);
      final deposit = (await rows()).firstWhere(
        (r) => r.receiptNo == 'TJA0000016',
      );
      expect(deposit.otherBalanceMinor, 150000);
      final summary = (await savings.account(shwari.id))!;
      expect(summary.balanceMinor, 130000);
      // The first balance shows money from before the messages start.
      expect(summary.wasThereBeforeMinor, 100000);
      expect(summary.interestMinor, 0);
      final readings = await db.select(db.savingsReadings).get();
      expect(readings, hasLength(2));
      expect(readings.every((r) => r.fromMessage), isTrue);
    });

    test('reading the messages again changes nothing', () async {
      await ingestor.ingest([_shwariIn, _shwariOut], [_mpesa]);
      final before = await rows();
      final again = await ingestor.ingest(
        [_shwariIn, _shwariOut],
        [_mpesa],
        again: true,
      );
      expect(again.added, 0);
      expect(await rows(), hasLength(before.length));
      expect(await db.select(db.savingsReadings).get(), hasLength(2));
    });
  });

  group('Etica MMF', () {
    Future<void> expectOneMove() async {
      final etica = await productAccount('etica');
      expect(etica.name, 'Etica MMF');
      expect(etica.type, AccountType.moneyMarket);
      expect(etica.familyOf, isNull);
      final mpesa = await wallet();
      final back = (await rows(accountId: mpesa.id))
          .singleWhere((r) => r.receiptNo == 'TJA0000035');
      final notice = (await rows(accountId: etica.id))
          .singleWhere((r) => r.messageHash != null);
      expect(back.transferPairId, notice.id);
      expect(notice.transferPairId, back.id);
      // No mirror is left beside the notice.
      final onEtica = await rows(accountId: etica.id);
      expect(
        onEtica.where((r) => r.direction == TransactionDirection.outflow),
        hasLength(1),
      );
      expect(await roleFor('TJA0000020'), LedgerRole.ownTransfer);
      expect(
        await roleFor('TJA0000035', accountId: mpesa.id),
        LedgerRole.ownTransfer,
      );
      expect((await totals()).incomeMinor, 0);
      expect((await savings.account(etica.id))!.balanceMinor, 60000);
    }

    test('its notice and the M-Pesa receipt are one move, the notice '
        'first', () async {
      await ingestor.ingest([_eticaNotice], [_mpesa, _etica]);
      await ingestor.ingest([_eticaIn, _eticaBack], [_mpesa, _etica]);
      await expectOneMove();
    });

    test('its notice and the M-Pesa receipt are one move, the receipt '
        'first', () async {
      await ingestor.ingest([_eticaIn, _eticaBack], [_mpesa, _etica]);
      await ingestor.ingest([_eticaNotice], [_mpesa, _etica]);
      await expectOneMove();
    });
  });

  group('Pochi la Biashara', () {
    test('is its own account with the balance its message prints, never '
        "the wallet's", () async {
      await ingestor.ingest([_till, _pochi], [_mpesa]);
      final all = await accounts();
      final pochi = all.singleWhere((a) => isPochiReference(a.reference));
      final mpesa = await wallet();
      expect(pochi.name, pochiName);
      expect(pochi.familyOf, mpesa.id);
      final sale = (await rows(accountId: pochi.id)).single;
      expect(sale.balanceAfterMinor, 120000);
      expect(sale.direction, TransactionDirection.inflow);
      expect((await rows(accountId: mpesa.id)).map((r) => r.receiptNo), [
        'TJA0000040',
      ]);
    });
  });

  group('repair on update', () {
    Future<int> stored(
      int account,
      String receipt,
      int amount,
      TransactionDirection direction,
      TransactionKind kind,
      String name, {
      int? category,
      DateTime? at,
    }) => db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            accountId: account,
            occurredAt: at ?? _eat(3, 10),
            amountMinor: amount,
            direction: direction,
            kind: Value(kind),
            currency: const Value('KES'),
            counterpartyName: Value(name),
            receiptNo: Value(receipt),
            categoryOverrideId: Value(category),
            source: TransactionSource.sms,
            messageHash: Value('hash-$receipt'),
          ),
        );

    test('plain sends and receipts to ZIIDI, M-Shwari and ETICA become '
        'transfers, once, and what the person set stays', () async {
      final mpesa = await db
          .into(db.accounts)
          .insert(
            AccountsCompanion.insert(
              name: 'M-Pesa',
              type: AccountType.mpesa,
              openingDate: DateTime.utc(2026),
              institutionId: const Value('mpesa'),
            ),
          );
      final category = await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(
              name: 'Rainy day',
              type: CategoryType.expense,
            ),
          );
      final ziidiSend = await stored(
        mpesa,
        'TJB0000001',
        100000,
        TransactionDirection.outflow,
        TransactionKind.sent,
        'ZIIDI',
        category: category,
      );
      await stored(
        mpesa,
        'TJB0000002',
        30000,
        TransactionDirection.inflow,
        TransactionKind.received,
        'M-Shwari',
        at: _eat(4, 10),
      );
      await stored(
        mpesa,
        'TJB0000003',
        20000,
        TransactionDirection.inflow,
        TransactionKind.received,
        'ETICA CAPITAL LTD',
        at: _eat(5, 10),
      );
      // The person said this one went to another account of theirs.
      final cash = await db
          .into(db.accounts)
          .insert(
            AccountsCompanion.insert(
              name: 'Cash',
              type: AccountType.cash,
              openingDate: DateTime.utc(2026),
            ),
          );
      final named = await stored(
        mpesa,
        'TJB0000004',
        5000,
        TransactionDirection.outflow,
        TransactionKind.sent,
        'ZIIDI',
        at: _eat(6, 10),
      );
      await (db.update(db.transactions)..where((t) => t.id.equals(named)))
          .write(TransactionsCompanion(transferAccountId: Value(cash)));

      final repaired = await repairBalancesOnce(db);
      expect(repaired, isNotNull);
      final ziidiAccount = await productAccount('ziidi');
      await productAccount('mshwari');
      await productAccount('etica');
      for (final receipt in ['TJB0000001', 'TJB0000002', 'TJB0000003']) {
        expect(
          await roleFor(receipt, accountId: mpesa),
          LedgerRole.ownTransfer,
          reason: receipt,
        );
      }
      final send = (await rows()).singleWhere((r) => r.id == ziidiSend);
      expect(send.categoryOverrideId, category);
      expect(send.transferAccountId, ziidiAccount.id);
      final kept = (await rows()).singleWhere((r) => r.id == named);
      expect(kept.transferAccountId, cash);
      expect((await savings.account(ziidiAccount.id))!.balanceMinor, 100000);

      // Once: running again changes nothing.
      final before = await rows();
      expect(await repairBalancesOnce(db), isNull);
      expect(await rows(), hasLength(before.length));
    });
  });

  test('the M-Shwari balance a message prints', () {
    expect(
      mshwariBalanceIn(
        'TJA0000034 Confirmed.Ksh300.00 transferred to M-Shwari account on '
        '13/11/26 at 10:30 AM. M-PESA balance is Ksh1,200.50 .New M-Shwari '
        'saving account balance is Ksh1,300.00. Transaction cost Ksh.0.00',
      ),
      130000,
    );
    expect(
      mshwariBalanceIn(
        'TJA0000033 Confirmed.Ksh500.00 transferred from M-Shwari account on '
        '13/11/26 at 10:00 AM. M-Shwari balance is Ksh1,000.00 .M-PESA '
        'balance is Ksh1,500.50 .Transaction cost Ksh.0.00',
      ),
      100000,
    );
    expect(mshwariBalanceIn('Ksh100.00 sent to JOHN DOE'), isNull);
  });
}
