import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/repositories/accounts_repository.dart';
import 'package:pesaclarity/src/data/repositories/review_inbox_repository.dart';
import 'package:pesaclarity/src/data/repositories/statement_imports_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';
import 'package:pesaclarity/src/features/accounts/domain/institution.dart';
import 'package:pesaclarity/src/features/sms/application/sms_ingestor.dart';
import 'package:pesaclarity/src/features/statements/application/statement_importer.dart';
import 'package:pesaclarity/src/features/statements/application/statement_password_hints.dart';
import 'package:pesaclarity/src/features/statements/data/pdfium_text_extractor.dart';
import 'package:ujumbe/ujumbe.dart';

import '../../helpers/test_app.dart';

/// The PDFium library the build hook fetched for this host, which
/// `flutter test` does not load on its own.
String? _hostPdfium() {
  final build = Directory('.dart_tool/hooks_runner/shared/pdfium_dart/build');
  if (!build.existsSync()) return null;
  for (final entity in build.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('/libpdfium.so')) {
      return entity.absolute.path;
    }
  }
  return null;
}

// The KCB fixture is a synthetic four-page statement written by
// tool/fixtures/statement_pdfs.py: JANE DOE's made-up account 1234567890,
// made-up FT references and amounts, rows cut by page breaks, charges, the
// period overlaid on the table and a closing summary page. Its locked copy
// opens with 5678, the 5th to the 8th digits of the account number.
void main() {
  final pdfium = _hostPdfium();
  if (pdfium == null) {
    test('PDFium is not built for this host', () {}, skip: true);
    return;
  }

  late AppDatabase db;
  late StatementImporter importer;
  final plain = File('test/fixtures/synthetic_kcb_statement.pdf')
      .readAsBytesSync();
  final locked = File('test/fixtures/synthetic_kcb_statement_locked.pdf')
      .readAsBytesSync();

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('pdfrx');
    addTearDown(() => dir.delete(recursive: true));
    Pdfrx.pdfiumModulePath = pdfium;
    // One extractor for every test: PDFium starts once per isolate.
    _extractor = PdfiumTextExtractor(tempDirectory: dir.path);
  });

  setUp(() {
    db = openTestDatabase();
    importer = StatementImporter(
      extractor: _extractor,
      read: (pages) async => readStatement(pages),
      accounts: DriftAccountsRepository(db),
      transactions: DriftTransactionsRepository(db),
      imports: DriftStatementImportsRepository(db),
      institutions: institutionCatalogue,
      now: () => DateTime.utc(2026, 10, 8, 9),
    );
  });

  Future<List<TransactionRecord>> transactions() => (db.select(
    db.transactions,
  )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();

  Future<void> ingest(List<SmsMessage> messages) => SmsIngestor(
    accounts: DriftAccountsRepository(db),
    transactions: DriftTransactionsRepository(db),
    reviewInbox: DriftReviewInboxRepository(db),
    parse: (packs, messages) async => parseAll(packs, messages),
  ).ingest(messages, institutionCatalogue);

  test('reads every row of the KCB statement and reconciles', () async {
    final outcome = await importer.importPdf(plain);

    final summary = (outcome as StatementImported).summary;
    expect(summary.institutionName, 'KCB');
    expect(summary.firstDay, CalendarDate(2026, 9, 1));
    expect(summary.lastDay, CalendarDate(2026, 9, 30));
    expect(summary.transactionCount, 10, reason: 'five charges fold in');
    expect(summary.addedCount, 10);
    expect(summary.unreadCount, 0);
    expect(summary.closingBalanceMinor, 5708500);
    expect(summary.reconciles, isTrue);

    final rows = await transactions();
    expect(rows.map((r) => r.source).toSet(), {TransactionSource.statement});
    final byReceipt = {for (final r in rows) r.receiptNo: r};
    expect(byReceipt['FT26244AAA01']!.kind, TransactionKind.received);
    expect(byReceipt['FT26244AAA01']!.feeMinor, 5000);
    expect(byReceipt['FT26244AAA01']!.counterpartyName, 'EXAMPLE EMPLOYER LTD');
    expect(byReceipt['FT26244AAA02']!.kind, TransactionKind.sent);
    expect(byReceipt['FT26244AAA02']!.feeMinor, 3000);
    expect(byReceipt['FT26244AAA02']!.counterpartyName, 'JOHN DOE');
    expect(byReceipt['FT26245AAA03']!.counterpartyName, 'JOHN DOE');
    expect(byReceipt['FT26245AAA03']!.feeMinor, 4500);
    expect(byReceipt['FT26245AAA04']!.kind, TransactionKind.bank);
    expect(byReceipt['FT26245AAA04']!.direction, TransactionDirection.inflow);
    expect(byReceipt['FT26246AAA05']!.counterpartyName, 'EXAMPLE SUPERMARKET');
    expect(byReceipt['FT26247AAA08']!.kind, TransactionKind.loanRepayment);
    expect(byReceipt['FT26248AAA10']!.amountMinor, 10000);

    final account = await db.select(db.accounts).getSingle();
    expect(account.institutionId, 'kcb');
    expect(account.openingBalanceMinor, 5000000);

    final record = await db.select(db.imports).getSingle();
    expect(record.institutionId, 'kcb');
    expect(record.result, StatementImportResult.reconciled);
    expect(record.periodStart.toUtc(), DateTime.utc(2026, 9));
    expect(record.periodEnd.toUtc(), DateTime.utc(2026, 9, 30));
  });

  test('after the KCB SMS, adds only what they missed', () async {
    await ingest([
      // Carries the statement's FT reference.
      SmsMessage(
        sender: 'KCB',
        body:
            'Dear Customer, KES 1,500.00 has been debited from your account '
            '****7890 on 01/09/2026 at 09:30. Transaction Ref: FT26244AAA02. '
            'Your available balance is KES 68,450.00.',
        receivedAt: DateTime.utc(2026, 9, 1, 6, 30, 5),
      ),
      // Prints no reference: the same amount on the same day.
      SmsMessage(
        sender: 'KCB',
        body:
            'Dear Customer, your acc ****7890 has been debited KES 5,000.00 '
            'Pesalink Outgoing at KCB DATA PROCESSING CENTRE at 10:12:30 on '
            '02 SEP 2026. For any queries call KCB on  +254700000000',
        receivedAt: DateTime.utc(2026, 9, 2, 7, 12, 40),
      ),
    ]);
    expect(await transactions(), hasLength(2));

    final outcome = await importer.importPdf(plain);

    final summary = (outcome as StatementImported).summary;
    expect(summary.transactionCount, 10);
    expect(summary.duplicateCount, 2);
    expect(summary.addedCount, 8);
    expect(summary.gapMinor, 0, reason: 'the SMS rows take their charges');
    final rows = await transactions();
    expect(rows, hasLength(10));
    final sms = rows.where((r) => r.source == TransactionSource.sms).toList();
    expect(sms.map((r) => r.amountMinor), [150000, 500000]);
    expect(sms.map((r) => r.feeMinor), [3000, 4500]);
  });

  test(
    'a send to the person\'s own M-Pesa number is an own transfer',
    () async {
      await ingest([
        SmsMessage(
          sender: 'MPESA',
          body:
              'TJA0000051 Confirmed.You have received Ksh2,500.00 from KCB 1 '
              '522522 on 4/9/26 at 2:15 PM New M-PESA balance is Ksh5,000.50.',
          receivedAt: DateTime.utc(2026, 9, 4, 11, 15, 10),
        ),
      ]);
      // The M-Pesa account is kept under JANE DOE's made-up number.
      await (db.update(db.accounts)
            ..where((a) => a.institutionId.equals('mpesa')))
          .write(const AccountsCompanion(reference: Value('0700000001')));

      await importer.importPdf(plain);

      final rows = await transactions();
      final mpesa = rows.singleWhere((r) => r.receiptNo == 'TJA0000051');
      final kcb = rows.singleWhere((r) => r.receiptNo == 'FT26247AAA07');
      expect(kcb.transferPairId, mpesa.id);
      expect(mpesa.transferPairId, kcb.id);
      final other = rows.singleWhere((r) => r.receiptNo == 'FT26248AAA09');
      expect(other.transferPairId, isNull, reason: 'someone else\'s number');
    },
  );

  test('the locked copy asks for the password the hint describes', () async {
    expect(
      await importer.importPdf(locked),
      isA<StatementNeedsPassword>().having(
        (o) => o.wrongPassword,
        'wrongPassword',
        isFalse,
      ),
    );
    expect(
      await importer.importPdf(locked, password: '1234'),
      isA<StatementNeedsPassword>().having(
        (o) => o.wrongPassword,
        'wrongPassword',
        isTrue,
      ),
    );
    // The 5th to the 8th digits of 1234567890.
    expect(
      await importer.importPdf(locked, password: '5678'),
      isA<StatementImported>(),
    );
    expect(
      statementPasswordHints[loadBundledStatementPack('kcb_statement')
          .passwordHint],
      'KCB statements open with 4 digits of your account number: the 5th to '
      'the 8th.',
    );
  });
}

late PdfiumTextExtractor _extractor;
