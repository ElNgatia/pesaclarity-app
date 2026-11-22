import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/repositories/accounts_repository.dart';
import 'package:pesaclarity/src/data/repositories/message_reads_repository.dart';
import 'package:pesaclarity/src/data/repositories/review_inbox_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/features/accounts/domain/institution.dart';
import 'package:pesaclarity/src/features/sms/application/paste_messages.dart';
import 'package:pesaclarity/src/features/sms/application/sms_ingestor.dart';
import 'package:pesaclarity/src/features/sms/application/transaction_mapping.dart';
import 'package:ujumbe/ujumbe.dart';

import '../../helpers/sms_samples.dart';
import '../../helpers/test_app.dart';

Institution _institution(String id) =>
    institutionCatalogue.singleWhere((i) => i.id == id);

void main() {
  late AppDatabase db;
  late SmsIngestor ingestor;
  var elsewhere = <String>{};

  PasteReader reader() => PasteReader(
    parse: (packs, messages) async => parseAll(packs, messages),
    ingestor: ingestor,
    now: () => DateTime.utc(2026, 11, 22, 9),
    reads: MessageReadsRepository(db),
    heldElsewhere: (hashes) async => hashes.intersection(elsewhere),
    storedKeys: (keys) => storedDedupeKeys(db, keys),
  );

  setUp(() {
    db = openTestDatabase();
    elsewhere = {};
    Future<Set<String>> heldElsewhere(Set<String> hashes) async =>
        hashes.intersection(elsewhere);
    ingestor = SmsIngestor(
      accounts: DriftAccountsRepository(db),
      transactions: DriftTransactionsRepository(db),
      reviewInbox: DriftReviewInboxRepository(
        db,
        clock: () => DateTime.utc(2026, 11),
      ),
      reads: MessageReadsRepository(db),
      parse: (packs, messages) async => parseAll(packs, messages),
      heldElsewhere: heldElsewhere,
    );
  });

  final mpesa = [_institution('mpesa'), _institution('kcb')];

  test('finds each payment in a paste, newest first, with no sender', () async {
    final text =
        '${mpesaSent().body}\n${mpesaTill().body}\n\n${mpesaNotice().body}';
    final reading = await reader().read(text, mpesa);

    expect(reading.payments.map((p) => p.parsed.receipt), [
      'TJA0000004',
      'TJA0000001',
    ]);
    expect(reading.notPayments, 1);
    expect(reading.newCount, 2);
    // Read as a message from M-Pesa, at the time the message prints.
    final till = reading.payments.first.message;
    expect(till.sender, 'MPESA');
    expect(till.body, mpesaTill().body);
    expect(till.receivedAt, reading.payments.first.parsed.time);
  });

  test('a message Shortcuts passed on is already in, and not added '
      'again', () async {
    await ingestor.ingest([mpesaSent()], mpesa);
    final reading = await reader().read(
      '${mpesaSent().body}\n\n${mpesaTill().body}',
      mpesa,
    );
    expect(reading.alreadyIn, 1);
    expect(reading.newCount, 1);

    final added = await reader().add(reading, mpesa);
    expect(added.summary.added, 1);
    final rows = await db.select(db.transactions).get();
    expect(rows.map((r) => r.receiptNo).toSet(), {'TJA0000001', 'TJA0000004'});
    // The newest message's balance, to check the account against.
    expect(added.newestBalance?.institutionId, 'mpesa');
    expect(added.newestBalance?.balanceMinor, 368500);
  });

  test('pasting the same paste twice adds nothing the second time', () async {
    final text = '${mpesaSent().body}\n${mpesaTill().body}';
    final first = await reader().read(text, mpesa);
    expect((await reader().add(first, mpesa)).summary.added, 2);

    final again = await reader().read('$text\n\n$text', mpesa);
    expect(again.payments, hasLength(2));
    expect(again.newCount, 0);
    expect(await db.select(db.transactions).get(), hasLength(2));
  });

  test('a message another space holds stays there', () async {
    elsewhere = {hashMessageBody(mpesaSent().body)};
    final reading = await reader().read(mpesaSent().body, mpesa);
    expect(reading.alreadyIn, 1);
    expect((await reader().add(reading, mpesa)).summary.added, 0);
    expect(await db.select(db.transactions).get(), isEmpty);
  });

  test('the same payment from a statement is already in', () async {
    await ingestor.ingest([mpesaTill()], mpesa);
    final account = await db.select(db.accounts).getSingle();
    final parsed = SmsParser([
      _institution('mpesa').pack,
    ]).parse(mpesaSent()) as ParsedTransaction;
    // As a statement import stores it: no message, the same dedupe key.
    await db
        .into(db.transactions)
        .insert(
          transactionFromParsed(parsed, accountId: account.id).copyWith(
            messageHash: const Value(null),
            source: const Value(TransactionSource.statement),
          ),
        );
    final reading = await reader().read(mpesaSent().body, mpesa);
    expect(reading.alreadyIn, 1);
    expect((await reader().add(reading, mpesa)).summary.added, 0);
    expect(await db.select(db.transactions).get(), hasLength(2));
  });

  test('text that is not a payment is left out and kept nowhere', () async {
    final reading = await reader().read(
      'SKZ0000000 Confirmed. Something no reader knows.\n\n'
      'Hello, see you at 6.',
      mpesa,
    );
    expect(reading.payments, isEmpty);
    expect(reading.notPayments, 2);
    await reader().add(reading, mpesa);
    expect(await db.select(db.reviewItems).get(), isEmpty);
    expect(await db.select(db.transactions).get(), isEmpty);
  });

  test('a bank message is read with its own readers', () async {
    final reading = await reader().read(kcbDebit().body, mpesa);
    expect(reading.payments.single.parsed.packId, 'kcb');
    expect(reading.payments.single.message.sender, 'KCB');
  });
}
