import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/repositories/accounts_repository.dart';
import 'package:pesaclarity/src/data/repositories/balances_repair.dart';
import 'package:pesaclarity/src/data/repositories/journal_repository.dart';
import 'package:pesaclarity/src/data/repositories/message_reads_repository.dart';
import 'package:pesaclarity/src/data/repositories/review_inbox_repository.dart';
import 'package:pesaclarity/src/data/repositories/savings_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/domain/accounts/mpesa_family.dart';
import 'package:pesaclarity/src/domain/books/book_account.dart';
import 'package:pesaclarity/src/domain/books/journal_balances.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_entry.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_role.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_totals.dart';
import 'package:pesaclarity/src/domain/savings/savings_product.dart';
import 'package:pesaclarity/src/features/accounts/application/pochi_ask.dart';
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
      expect((await savings.prompt())?.product, ziidi);
      await savings.add(ziidi, at: _eat(20, 9));
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
      // Added: not asked about again.
      expect(await savings.prompt(), isNull);
    });

    test('a balance the person types is its value; the rest is returns, '
        'income under Interest', () async {
      await ingestor.ingest([_ziidiIn, _ziidiOut], [_mpesa]);
      await savings.add(ziidi, at: _eat(20, 9));
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
      await savings.add(mshwari, at: _eat(20, 9));
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
      await savings.add(mshwari, at: _eat(20, 9));
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
      expect((await savings.prompt())?.product, eticaMmf);
      await savings.add(eticaMmf, at: _eat(20, 9));
      await expectOneMove();
      // New messages join the account added.
      await ingestor.ingest([_eticaNotice], [_mpesa, _etica], again: true);
      await expectOneMove();
    });

    test('its notice and the M-Pesa receipt are one move, the receipt '
        'first', () async {
      await savings.add(eticaMmf, at: _eat(9, 9));
      await ingestor.ingest([_eticaIn, _eticaBack], [_mpesa, _etica]);
      await ingestor.ingest([_eticaNotice], [_mpesa, _etica]);
      await expectOneMove();
    });
  });

  group('Pochi la Biashara', () {
    PochiAsk pochiAsk() => PochiAsk(db, ingestor: ingestor, mpesa: _mpesa);

    Future<List<ReviewItem>> waiting() =>
        (db.select(db.reviewItems)..where((r) => r.resolvedAt.isNull())).get();

    test('waits to be asked about, off the records and the wallet, until '
        'Add makes it its own account with the balance its message '
        'prints', () async {
      await ingestor.ingest([_till, _pochi], [_mpesa]);
      // No account before the answer: the message waits, as it is.
      expect(
        (await accounts()).where((a) => isPochiReference(a.reference)),
        isEmpty,
      );
      final held = await waiting();
      expect(held.single.reason, pochiAskReason);
      expect(held.single.body, _pochi.body);
      final mpesa = await wallet();
      expect((await rows()).map((r) => r.receiptNo), ['TJA0000040']);
      final ask = pochiAsk();
      expect((await ask.waiting())!.payments, 1);
      expect((await ask.waiting())!.declined, isFalse);
      // Reading the messages again keeps it waiting, once.
      await ingestor.ingest([_till, _pochi], [_mpesa], again: true);
      expect(await waiting(), hasLength(1));

      expect(await ask.add(), 1);
      final pochi = (await accounts()).singleWhere(
        (a) => isPochiReference(a.reference),
      );
      expect(pochi.name, pochiName);
      expect(pochi.familyOf, mpesa.id);
      final sale = (await rows(accountId: pochi.id)).single;
      expect(sale.balanceAfterMinor, 120000);
      expect(sale.direction, TransactionDirection.inflow);
      expect((await rows(accountId: mpesa.id)).map((r) => r.receiptNo), [
        'TJA0000040',
      ]);
      expect(await waiting(), isEmpty);
      expect(await ask.waiting(), isNull);
    });

    test('Not now is kept, never asked again, and the payments keep waiting '
        'for Add later', () async {
      await ingestor.ingest([_till, _pochi], [_mpesa]);
      final ask = pochiAsk();
      await ask.decline();
      expect((await ask.waiting())!.declined, isTrue);
      await ingestor.ingest([_pochi], [_mpesa], again: true);
      expect((await ask.waiting())!.declined, isTrue);
      expect(
        (await accounts()).where((a) => isPochiReference(a.reference)),
        isEmpty,
      );
      // The wallet holds only its own money.
      expect((await rows()).map((r) => r.receiptNo), ['TJA0000040']);
      // Added later, from Add or remove accounts.
      expect(await ask.add(), 1);
      expect(await ask.waiting(), isNull);
    });

    test('made before it was asked about: no question', () async {
      final mpesa = await DriftAccountsRepository(db).accountForInstitution(
        'mpesa',
        name: 'M-Pesa',
        type: AccountType.mpesa,
        openingDate: _eat(1, 9),
        currency: 'KES',
      );
      await DriftAccountsRepository(db).accountForInstitution(
        'mpesa',
        name: pochiName,
        type: AccountType.other,
        openingDate: _eat(1, 9),
        currency: 'KES',
        reference: pochiReference,
      );
      await ingestor.ingest([_pochi], [_mpesa]);
      expect(await pochiAsk().waiting(), isNull);
      final pochi = (await accounts()).singleWhere(
        (a) => isPochiReference(a.reference),
      );
      expect(pochi.familyOf, mpesa);
      expect(await rows(accountId: pochi.id), hasLength(1));
    });
  });

  group('asked before adding (0026 item 5)', () {
    Future<JournalBalances> books() async {
      final journal = JournalRepository(db, clock: () => _eat(21, 9));
      await journal.sync();
      return journal.read();
    }

    Future<int> walletBooks() async => (await books()).balanceOf(
      BookAccount.money((await wallet()).id),
      currency: 'KES',
    );

    test('no account exists before the answer, and the moves wait as own '
        'transfers with the wallet as its messages print it', () async {
      await ingestor.ingest([_ziidiIn, _ziidiOut, _shwariIn], [_mpesa]);
      expect((await accounts()).where((a) => a.product != null), isEmpty);
      expect((await accounts()).map((a) => a.type), [AccountType.mpesa]);
      for (final receipt in ['TJA0000030', 'TJA0000031', 'TJA0000016']) {
        expect(await roleFor(receipt), LedgerRole.ownTransfer, reason: receipt);
      }
      final sums = await totals();
      expect(sums.incomeMinor, 0);
      expect(sums.spendingMinor, 0);
      // Asked about one at a time, M-Shwari first, in its own words.
      final first = (await savings.prompt())!;
      expect(first.product, mshwari);
      expect(mshwari.askedAs, 'M-Shwari savings');
      expect(
        first.transactionId,
        (await rows()).singleWhere((r) => r.receiptNo == 'TJA0000016').id,
      );
      // Only the family is asked outside Personal.
      expect((await savings.prompt(apps: false))?.product, mshwari);
      // The wallet as its last message prints it: Ksh650.00.
      expect(await walletBooks(), 65000);
    });

    test('Add makes the account and turns every past move into a '
        'transfer', () async {
      await ingestor.ingest([_ziidiIn, _ziidiOut], [_mpesa]);
      final before = await walletBooks();
      final added = await savings.add(
        ziidi,
        at: _eat(20, 9),
        promptedTransactionId: (await savings.prompt())!.transactionId,
      );
      expect(added.linked, 2);
      final account = await productAccount('ziidi');
      expect(account.familyOf, (await wallet()).id);
      final moves = await rows(accountId: (await wallet()).id);
      expect(moves.every((r) => r.transferAccountId == account.id), isTrue);
      expect(moves.every((r) => r.transferPairId != null), isTrue);
      expect((await savings.account(account.id))!.balanceMinor, 40000);
      expect(await savings.prompt(), isNull);
      expect((await savings.addedNotice())!.updated, 1);
      expect(await walletBooks(), before);
      // Ziidi holds what was moved; nothing else changed.
      expect(
        (await books()).balanceOf(
          BookAccount.money(account.id),
          currency: 'KES',
        ),
        40000,
      );
    });

    test('Not now keeps the old categorisation and never asks again', () async {
      await ingestor.ingest([_ziidiIn, _ziidiOut], [_mpesa]);
      final before = await walletBooks();
      await savings.decline('ziidi');
      // As before the family was read: a send, and money from someone not
      // named yet.
      expect(await roleFor('TJA0000030'), LedgerRole.spending);
      expect(await roleFor('TJA0000031'), LedgerRole.awaitingPayee);
      final sums = await totals();
      expect(sums.spendingMinor, 100000);
      expect((await accounts()).where((a) => a.product != null), isEmpty);
      expect(await savings.prompt(), isNull);
      // New moves do not bring the question back.
      await ingestor.ingest([_ziidiIn, _ziidiOut], [_mpesa], again: true);
      expect(await savings.prompt(), isNull);
      expect(await walletBooks(), before);
      // The journal posts the answer: the send is spending there too.
      expect(
        (await books()).balanceOf(BookAccount.ownTransfers, currency: 'KES'),
        0,
      );
    });

    test('a category the person chose stays theirs while it waits', () async {
      await ingestor.ingest([_ziidiIn], [_mpesa]);
      final category = await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(
              name: 'Rainy day',
              type: CategoryType.expense,
            ),
          );
      await (db.update(db.transactions)
            ..where((t) => t.receiptNo.equals('TJA0000030')))
          .write(TransactionsCompanion(categoryOverrideId: Value(category)));
      expect(await roleFor('TJA0000030'), LedgerRole.spending);
    });

    test('the upgrade from accounts made without asking keeps them, as '
        'added, and asks nothing', () async {
      // As the first version of the family left them: accounts made from
      // the messages, before the question was asked.
      await ingestor.ingest([_ziidiIn, _shwariIn], [_mpesa]);
      final mpesa = (await wallet()).id;
      for (final product in [ziidi, mshwari]) {
        await db
            .into(db.accounts)
            .insert(
              AccountsCompanion.insert(
                name: product.name,
                type: product.type,
                openingDate: _eat(1, 9),
                product: Value(product.id),
                familyOf: Value(mpesa),
              ),
            );
      }
      await repairBalances(db);
      expect(await savings.prompt(), isNull);
      expect(await roleFor('TJA0000030'), LedgerRole.ownTransfer);
      expect(await roleFor('TJA0000016'), LedgerRole.ownTransfer);
      expect(
        (await rows())
            .where((r) => r.receiptNo == 'TJA0000030')
            .single
            .transferAccountId,
        (await productAccount('ziidi')).id,
      );
      expect(await walletBooks(), 5000);
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

    test('plain sends and receipts to ZIIDI, M-Shwari and ETICA make no '
        'account; each waits for its question, then becomes a transfer on '
        'Add, and what the person set stays', () async {
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
      expect((await accounts()).where((a) => a.product != null), isEmpty);
      for (final receipt in ['TJB0000002', 'TJB0000003']) {
        expect(
          await roleFor(receipt, accountId: mpesa),
          LedgerRole.ownTransfer,
          reason: receipt,
        );
      }
      // The person's own category stays theirs.
      expect(
        await roleFor('TJB0000001', accountId: mpesa),
        LedgerRole.spending,
      );

      for (final product in [ziidi, mshwari, eticaMmf]) {
        await savings.add(product, at: _eat(20, 9));
      }
      final ziidiAccount = await productAccount('ziidi');
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
