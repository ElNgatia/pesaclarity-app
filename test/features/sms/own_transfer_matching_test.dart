import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/repositories/accounts_repository.dart';
import 'package:pesaclarity/src/data/repositories/balances_repair.dart';
import 'package:pesaclarity/src/data/repositories/own_moves.dart';
import 'package:pesaclarity/src/data/repositories/review_inbox_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/domain/ledger/message_twins.dart';
import 'package:pesaclarity/src/features/accounts/domain/institution.dart';
import 'package:pesaclarity/src/features/sms/application/sms_ingestor.dart';
import 'package:ujumbe/ujumbe.dart';

import '../../helpers/test_app.dart';

// Decision 0030, end to end: messages in the shapes the packs read, with
// made-up names, numbers, codes, amounts and times.

List<Institution> _institutions(List<String> ids) => [
  for (final id in ids) institutionCatalogue.singleWhere((i) => i.id == id),
];

SmsMessage _sms(String sender, String body, DateTime at) =>
    SmsMessage(sender: sender, body: body, receivedAt: at);

SmsMessage _mpesaReceived(
  String ref,
  String amount,
  String from,
  String time, {
  String day = '26/10/26',
}) => _sms(
  'MPESA',
  '$ref Confirmed.You have received Ksh$amount from $from on $day at $time '
      'New M-PESA balance is Ksh9,000.00.',
  DateTime.utc(2026, 10, 26, 6),
);

SmsMessage _kcbToWallet({String ref = 'M-PESA REF: TJA0000001'}) => _sms(
  'KCB',
  'KCB0000000000003  KES 1,000.00 sent from 123****456 to 254****789 - JANE '
      'DOE on 2026-10-26 09:15:00 AM. $ref',
  DateTime.utc(2026, 10, 26, 6, 15),
);

SmsMessage _kcbDebit(String ref, String time) => _sms(
  'KCB',
  'Dear Customer, KES 4,000.00 has been debited from your account '
      '1234****456 on 26/10/2026 at $time. Transaction Ref: $ref. Your '
      'available balance is KES 10,000.00.',
  DateTime.utc(2026, 10, 26, 6),
);

void main() {
  late AppDatabase db;
  late SmsIngestor ingestor;
  late DriftTransactionsRepository transactions;

  setUp(() {
    db = openTestDatabase();
    transactions = DriftTransactionsRepository(db);
    ingestor = SmsIngestor(
      accounts: DriftAccountsRepository(db),
      transactions: transactions,
      reviewInbox: DriftReviewInboxRepository(
        db,
        clock: () => DateTime.utc(2026, 11, 15),
      ),
    );
  });

  Future<List<TransactionRecord>> rows() =>
      (db.select(db.transactions)..orderBy([
            (t) => OrderingTerm.asc(t.occurredAt),
            (t) => OrderingTerm.asc(t.id),
          ]))
          .get();

  Future<int> accountOf(String institution) async => (await (db.select(
    db.accounts,
  )..where((a) => a.institutionId.equals(institution))).getSingle()).id;

  void expectPaired(TransactionRecord out, TransactionRecord into) {
    expect(out.direction, TransactionDirection.outflow);
    expect(into.direction, TransactionDirection.inflow);
    expect(out.transferPairId, into.id);
    expect(into.transferPairId, out.id);
  }

  group('one code on two accounts', () {
    test("M-Pesa to Airtel Money pair by Airtel's Sender TID", () async {
      await ingestor.ingest([
        _sms(
          'MPESA',
          'TJA0000037 Confirmed. Ksh100.00 sent to AIRTEL MONEY for account '
              '0730000000 on 14/11/26 at 3:00 PM New M-PESA balance is '
              'Ksh4,885.50. Transaction cost, Ksh15.00.',
          DateTime.utc(2026, 11, 14, 12),
        ),
        _sms(
          'AirtelMoney',
          'TID:TJA0000040. Received Ksh 100 from JANE DOE 254700000001 on '
              '14/11/26 03:00 PM. Bal:Ksh 220.0 Sender TID:TJA0000037.',
          DateTime.utc(2026, 11, 14, 12),
        ),
      ], _institutions(['mpesa', 'airtel_money']));
      final [out, into] = await rows();
      expect(into.receiptNo, 'TJA0000040');
      expect(into.linkedReceiptNo, 'TJA0000037');
      expect(into.counterpartyValue, isNull, reason: 'a code is no payee');
      expectPaired(out, into);
      expect(await ownMoveQuestions(db), isEmpty);
    });

    test('KCB to M-Pesa pair by the M-PESA REF, two hours apart', () async {
      await ingestor.ingest([
        _kcbToWallet(),
        _mpesaReceived('TJA0000001', '1,000.00', 'KCB 1 522522', '11:15 AM'),
      ], _institutions(['mpesa', 'kcb']));
      final [out, into] = await rows();
      expect(out.accountId, await accountOf('kcb'));
      expect(out.linkedReceiptNo, 'TJA0000001');
      expect(out.counterpartyValue, isNull);
      expect(into.accountId, await accountOf('mpesa'));
      expectPaired(out, into);
    });

    test("Equity to M-Pesa pair by Equity's MPESA Ref", () async {
      await ingestor.ingest([
        _sms(
          'EQUITYBANK',
          'Your transaction of Kshs. 200.0  has been credited to  '
              '254700000001  JANE DOE. Ref.  EQA0000000000001. MPESA Ref.  '
              'TJA0000002 on  26/10/2026 at 09:15:30.',
          DateTime.utc(2026, 10, 26, 6, 16),
        ),
        _mpesaReceived('TJA0000002', '200.00', 'EQUITY BULK 1', '10:30 AM'),
      ], _institutions(['mpesa', 'equity']));
      final [out, into] = await rows();
      expect(out.linkedReceiptNo, 'TJA0000002');
      expectPaired(out, into);
    });

    test("Etica to M-Pesa pair by Etica's Transaction ref", () async {
      await ingestor.ingest([
        _sms(
          'ETICALTD',
          'Dear esteemed client, Your payment of KES 400.00 to 0700000001 - '
              'JANE DOE from account 000000M (EMMF - KES) has been processed '
              'successfully. Transaction ref: TJA0000035',
          DateTime.utc(2026, 10, 26, 3),
        ),
        _mpesaReceived('TJA0000035', '400.00', 'ETICA CAPITAL LTD', '10:00 AM'),
      ], _institutions(['mpesa', 'etica']));
      final [out, into] = await rows();
      expectPaired(out, into);
    });
  });

  group('a guess is asked about once, remembered per sender', () {
    Future<void> firstGuess() => ingestor.ingest([
      _kcbDebit('KCBREF0000001', '09:00'),
      _mpesaReceived('TJB0000001', '4,000.00', 'KCB 1 522522', '9:05 AM'),
    ], _institutions(['mpesa', 'kcb']));

    Future<void> secondGuess() => ingestor.ingest([
      _kcbDebit('KCBREF0000002', '15:00'),
      _mpesaReceived('TJB0000002', '4,000.00', 'KCB 1 522522', '3:04 PM'),
    ], _institutions(['mpesa', 'kcb']));

    test('held as a move and asked about', () async {
      await firstGuess();
      final [out, into] = await rows();
      expectPaired(out, into);
      final asked = await ownMoveQuestions(db);
      expect(asked.keys, {out.id, into.id});
      expect(asked[out.id]!.senderName, 'KCB 1');
    });

    test('No: both count as they were, and the sender stays apart', () async {
      await firstGuess();
      final [out, into] = await rows();
      await transactions.answerOwnMove(out.id, into.id, yes: false);
      final now = await rows();
      expect(now.map((r) => r.transferPairId), [null, null]);
      expect(await ownMoveQuestions(db), isEmpty);

      await secondGuess();
      final later = await rows();
      expect(later.map((r) => r.transferPairId), everyElement(isNull));
      expect(await ownMoveQuestions(db), isEmpty);
    });

    test('Yes: kept, never asked again, and the sender pairs', () async {
      await firstGuess();
      final [out, into] = await rows();
      await transactions.answerOwnMove(out.id, into.id, yes: true);
      expect((await rows()).first.transferPairId, into.id);
      expect(await ownMoveQuestions(db), isEmpty);

      await secondGuess();
      final later = await rows();
      expect(later.map((r) => r.transferPairId), everyElement(isNotNull));
      expect(await ownMoveQuestions(db), isEmpty);
    });

    test('matching by hand counts as Yes', () async {
      await firstGuess();
      final [out, into] = await rows();
      await transactions.unmatch(out.id);
      await transactions.match(out.id, into.id);
      expect(await ownMoveQuestions(db), isEmpty);
    });
  });

  group('matching runs again when the readers change', () {
    test('history read before a pack read the code is matched', () async {
      await ingestor.ingest([
        _kcbToWallet(),
        _mpesaReceived('TJA0000001', '1,000.00', 'KCB 1 522522', '11:15 AM'),
      ], _institutions(['mpesa', 'kcb']));
      // As read before the pack kept the M-PESA REF: two hours apart, the
      // two sides never paired.
      await db
          .update(db.transactions)
          .write(
            const TransactionsCompanion(
              transferPairId: Value(null),
              linkedReceiptNo: Value(null),
            ),
          );
      await transactions.pairOwnTransfers();
      expect((await rows()).map((r) => r.transferPairId), [null, null]);

      // The first start with these readers matches the whole history.
      await repairBalancesOnce(db, readers: '0.4.0 kcb@0.4.1');
      expect((await rows()).map((r) => r.transferPairId), [null, null]);
      expect(await repairBalancesOnce(db, readers: '0.4.0 kcb@0.4.1'), isNull);

      // Reading the messages again with the new pack keeps the code; the
      // next start, with new readers, matches again.
      final kcbRow = (await rows()).first;
      await (db.update(
        db.transactions,
      )..where((t) => t.id.equals(kcbRow.id))).write(
        const TransactionsCompanion(linkedReceiptNo: Value('TJA0000001')),
      );
      final repaired = await repairBalancesOnce(db, readers: '0.4.0 kcb@0.4.2');
      expect(repaired, isNotNull);
      expect(repaired!.paired, 1);
      final [out, into] = await rows();
      expectPaired(out, into);
      expect(await repairBalancesOnce(db, readers: '0.4.0 kcb@0.4.2'), isNull);
    });

    test('a pair the rules now rule out is unmatched', () async {
      await ingestor.ingest([
        _sms(
          'MPESA',
          'TJA0000050 Confirmed. Ksh1,000.00 sent to JOHN DOE 0711000002 on '
              '14/11/26 at 3:00 PM. New M-PESA balance is Ksh4,000.00. '
              'Transaction cost, Ksh13.00.',
          DateTime.utc(2026, 11, 14, 12),
        ),
        _sms(
          'AirtelMoney',
          'TID:TJA0000051. Received Ksh 1,000 from MARY DOE 254722000003 on '
              '14/11/26 03:02 PM. Bal:Ksh 1,220.0 Sender TID:TJA9999999.',
          DateTime.utc(2026, 11, 14, 12, 2),
        ),
      ], _institutions(['mpesa', 'airtel_money']));
      final [out, into] = await rows();
      expect(out.transferPairId, isNull, reason: 'another sender TID');
      // As an earlier version paired them, by amount and time alone.
      await (db.update(db.transactions)..where((t) => t.id.equals(out.id)))
          .write(TransactionsCompanion(transferPairId: Value(into.id)));
      await (db.update(db.transactions)..where((t) => t.id.equals(into.id)))
          .write(TransactionsCompanion(transferPairId: Value(out.id)));

      final repaired = await repairBalancesOnce(db, readers: 'next');
      expect(repaired!.unpaired, 1);
      expect((await rows()).map((r) => r.transferPairId), [null, null]);
    });
  });

  test('every pack that sends a notice on M-Pesa is in the table', () {
    final senders = {
      for (final pack in loadBundledPacks())
        for (final rule in pack.rules)
          if (rule.institution == 'mpesa' &&
              pack.id != 'mpesa' &&
              (rule.direction == Direction.incoming ||
                  rule.directionValues.values.contains(Direction.incoming)))
            pack.id,
    };
    expect(senders, isNotEmpty);
    expect(walletNotices.keys.toSet(), containsAll(senders));
  });
}
