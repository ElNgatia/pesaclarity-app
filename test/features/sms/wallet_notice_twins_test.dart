import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/repositories/accounts_repository.dart';
import 'package:pesaclarity/src/data/repositories/balances_repair.dart';
import 'package:pesaclarity/src/data/repositories/journal_repository.dart';
import 'package:pesaclarity/src/data/repositories/message_reads_repository.dart';
import 'package:pesaclarity/src/data/repositories/review_inbox_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/features/accounts/domain/institution.dart';
import 'package:pesaclarity/src/features/sms/application/sms_ingestor.dart';
import 'package:ujumbe/ujumbe.dart';

import '../../helpers/test_app.dart';

// Money sent from someone's KCB account to this M-Pesa wallet: KCB sends a
// notice ("... received from GRACE NJERI - 987****641 ... via KCB") that its
// pack puts on M-Pesa, and M-Pesa sends its own message, which names the
// person. Counted as two, the wallet showed the money twice. Made-up names,
// numbers and references only.

final _selected = [
  for (final id in ['mpesa', 'kcb'])
    institutionCatalogue.singleWhere((i) => i.id == id),
];

SmsMessage _mpesa(String body, DateTime at) =>
    SmsMessage(sender: 'MPESA', body: body, receivedAt: at);

final _before = _mpesa(
  'TJC0000040 Confirmed. Ksh300.00 paid to EXAMPLE GROCERS. on 11/11/26 at '
  '1:45 PM.New M-PESA balance is Ksh1,200.00. Transaction cost, Ksh0.00. '
  'Amount you can transact within the day is 496,950.00.',
  DateTime.utc(2026, 11, 11, 10, 45, 5),
);

/// M-Pesa's own message: money in from [from], at 5:[minute] AM.
SmsMessage _received({
  String ref = 'TJC0000041',
  String from = 'GRACE NJERI 0700***041',
  String balance = '4,700.00',
  int minute = 41,
}) => _mpesa(
  '$ref Confirmed.You have received Ksh3,500.00 from $from on 12/11/26 at '
  '5:$minute AM New M-PESA balance is Ksh$balance.',
  DateTime.utc(2026, 11, 12, 2, minute, 10),
);

/// KCB's notice of the same money, 20 seconds into the minute.
SmsMessage _notice({
  String ref = 'KCB0000000000041',
  String from = 'GRACE NJERI - 987****641',
  int minute = 41,
}) => SmsMessage(
  sender: 'KCB',
  body:
      '$ref Confirmed.  KES 3,500.00 received from $from on 2026-11-12 '
      '05:$minute:20 AM via KCB.',
  receivedAt: DateTime.utc(2026, 11, 12, 2, minute, 30),
);

void main() {
  late AppDatabase db;

  SmsIngestor ingestorOf(AppDatabase db) => SmsIngestor(
    accounts: DriftAccountsRepository(db),
    transactions: DriftTransactionsRepository(db),
    reviewInbox: DriftReviewInboxRepository(
      db,
      clock: () => DateTime.utc(2026, 11, 12),
    ),
    reads: MessageReadsRepository(db),
  );

  setUp(() => db = openTestDatabase());

  Future<List<TransactionRecord>> rows([AppDatabase? of]) {
    final d = of ?? db;
    return (d.select(
      d.transactions,
    )..orderBy([(t) => OrderingTerm.asc(t.occurredAt)])).get();
  }

  /// What Balances shows M-Pesa holds.
  Future<int> wallet() async {
    final mpesa = await (db.select(
      db.accounts,
    )..where((a) => a.institutionId.equals('mpesa'))).getSingle();
    final opening = (await DriftAccountsRepository(
      db,
    ).openings()).singleWhere((o) => o.id == mpesa.id);
    return (await JournalRepository(
      db,
    ).read()).walletAt(opening, at: DateTime.utc(2027));
  }

  Future<void> ingest(Iterable<SmsMessage> messages) async {
    for (final m in messages) {
      await ingestorOf(db).ingest([m], _selected);
    }
  }

  for (final noticeFirst in [false, true]) {
    test('the notice and M-Pesa\'s message are one transaction '
        '(${noticeFirst ? 'notice' : 'M-Pesa'} first), kept as M-Pesa has '
        'it', () async {
      await ingest([
        _before,
        if (noticeFirst) _notice(),
        _received(),
        if (!noticeFirst) _notice(),
      ]);

      final money = (await rows()).where(
        (r) => r.direction == TransactionDirection.inflow,
      );
      expect(money, hasLength(1));
      final row = money.single;
      expect(row.receiptNo, 'TJC0000041');
      expect(row.balanceAfterMinor, 470000);
      expect(row.counterpartyName, 'GRACE NJERI');
      expect(
        {row.messageHash, row.twinMessageHash},
        {hashMessageBody(_received().body), hashMessageBody(_notice().body)},
      );
      expect(await wallet(), 470000, reason: 'not 8,200: counted once');

      // Read again, either message is the one transaction.
      await ingest([_notice(), _received()]);
      expect(
        (await rows()).where((r) => r.direction == TransactionDirection.inflow),
        hasLength(1),
      );
    });
  }

  test('a notice with no M-Pesa message of its own stays', () async {
    await ingest([_before, _notice()]);
    final money = (await rows()).where(
      (r) => r.direction == TransactionDirection.inflow,
    );
    expect(money.single.receiptNo, 'KCB0000000000041');
  });

  test('of two M-Pesa payments of the same amount, the notice goes with the '
      'one from the same sender, even when the other is nearer', () async {
    await ingest([
      _before,
      _received(ref: 'TJC0000042', from: 'PETER OTIENO 0700***042', minute: 40),
      _received(ref: 'TJC0000043', balance: '8,200.00', minute: 50),
      _notice(),
    ]);
    final money = (await rows()).where(
      (r) => r.direction == TransactionDirection.inflow,
    );
    expect(money, hasLength(2));
    final grace = money.singleWhere((r) => r.receiptNo == 'TJC0000043');
    expect(grace.twinMessageHash, hashMessageBody(_notice().body));
    expect(
      money.singleWhere((r) => r.receiptNo == 'TJC0000042').twinMessageHash,
      isNull,
    );
  });

  test('one M-Pesa message takes one notice: a second stays its own', () async {
    await ingest([
      _before,
      _received(),
      _notice(),
      _notice(ref: 'KCB0000000000044', minute: 42),
    ]);
    final money = (await rows()).where(
      (r) => r.direction == TransactionDirection.inflow,
    );
    expect(money, hasLength(2));
    expect(money.map((r) => r.receiptNo), contains('KCB0000000000044'));
  });

  test('a message read twice never makes a second row', () async {
    await ingest([_before, _received()]);
    // The same message through a second ingestor that does not look up what
    // was read (as a statement or a recheck would add it).
    final row = (await rows()).last;
    final copy = row
        .toCompanion(true)
        .copyWith(
          id: const Value.absent(),
          dedupeKey: const Value('another key for the same message'),
        );
    expect(await DriftTransactionsRepository(db).addNew([copy]), 0);
    expect(await rows(), hasLength(2));
  });

  group('the repair on update', () {
    /// The database as an earlier version left it: the notice and M-Pesa's
    /// message as two transactions on M-Pesa, and one message stored twice.
    Future<void> asBefore() async {
      await ingest([_before, _received()]);
      final scratch = openTestDatabase();
      await ingestorOf(scratch).ingest([_notice()], _selected);
      final notice = (await rows(scratch)).single;
      final mpesa = (await rows()).first.accountId;
      await db
          .into(db.transactions)
          .insert(
            notice
                .toCompanion(true)
                .copyWith(id: const Value.absent(), accountId: Value(mpesa)),
          );
      final first = (await rows()).first;
      await db
          .into(db.transactions)
          .insert(
            first
                .toCompanion(true)
                .copyWith(
                  id: const Value.absent(),
                  dedupeKey: const Value('a key from an older reader'),
                ),
          );
      await JournalRepository(db).sync();
    }

    test('merges the pair and removes the copy, and the wallet is right '
        'again', () async {
      await asBefore();
      expect(await rows(), hasLength(4));
      expect(await wallet(), 820000, reason: 'the doubled balance');

      final repaired = await repairBalancesOnce(db);
      expect(repaired?.walletCredits, 1);
      expect(repaired?.copies, 1);
      final now = await rows();
      expect(now, hasLength(2));
      expect(now.last.receiptNo, 'TJC0000041');
      expect(now.last.twinMessageHash, hashMessageBody(_notice().body));
      expect(await wallet(), 470000);
      expect(await JournalRepository(db).unbalanced(), isEmpty);

      // Once only, and reading the messages again brings nothing back.
      expect(await repairBalancesOnce(db), isNull);
      await ingest([_before, _received(), _notice()]);
      expect(await rows(), hasLength(2));
      expect(await wallet(), 470000);
    });
  });
}
