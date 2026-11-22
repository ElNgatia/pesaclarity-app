// A made-up M-Pesa user with M-Shwari, Ziidi, a Pochi la Biashara and
// Etica MMF (decision 0026), for the M-Pesa family screens in the
// accessibility check. The messages are synthetic, in the shape of the
// message packs' fixtures: every receipt, person, number, amount and date
// is invented.
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/repositories/accounts_repository.dart';
import 'package:pesaclarity/src/data/repositories/message_reads_repository.dart';
import 'package:pesaclarity/src/data/repositories/review_inbox_repository.dart';
import 'package:pesaclarity/src/data/repositories/savings_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/domain/savings/savings_product.dart'
    as products;
import 'package:pesaclarity/src/features/accounts/application/pochi_ask.dart';
import 'package:pesaclarity/src/features/accounts/domain/institution.dart';
import 'package:pesaclarity/src/features/sms/application/sms_ingestor.dart';
import 'package:ujumbe/ujumbe.dart';

import '../domain/fixtures.dart';

/// Saturday 21 November 2026, 09:41 in Nairobi.
final familyNow = eat(2026, 11, 21, 9, 41);

/// [at] in Nairobi as M-Pesa prints it: `2/11/26 at 9:05 AM`.
String _when(DateTime at, {bool withAt = true}) {
  final local = at.add(const Duration(hours: 3));
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final day = '${local.day}/${local.month}/${local.year % 100}';
  return '$day${withAt ? ' at' : ''} $hour:$minute '
      '${local.hour < 12 ? 'AM' : 'PM'}';
}

/// What [FamilyRecords.seed] made.
class FamilySeeded {
  const FamilySeeded({required this.ziidi, required this.mshwari});

  /// The accounts, once added; null while their question is open.
  final int? ziidi;
  final int? mshwari;
}

class FamilyRecords {
  FamilyRecords(this.db);

  final AppDatabase db;
  var _receipts = 0;

  String _receipt() => 'TMF${(++_receipts).toString().padLeft(7, '0')}';

  SmsMessage _mpesa(String body, DateTime at) => SmsMessage(
    sender: 'MPESA',
    body: body,
    receivedAt: at.add(const Duration(seconds: 5)),
  );

  SmsMessage _paid(DateTime at, String amount, String to, String balance) =>
      _mpesa(
        '${_receipt()} Confirmed. Ksh$amount paid to $to. on ${_when(at)}.'
        'New M-PESA balance is Ksh$balance. Transaction cost, Ksh0.00.',
        at,
      );

  SmsMessage _received(
    DateTime at,
    String amount,
    String from,
    String balance,
  ) => _mpesa(
    '${_receipt()} Confirmed.You have received Ksh$amount from $from on '
    '${_when(at)} New M-PESA balance is Ksh$balance.',
    at,
  );

  SmsMessage _toZiidi(DateTime at, String amount, String balance) => _mpesa(
    '${_receipt()} Confirmed. Ksh$amount sent to ZIIDI on ${_when(at)} '
    'New M-PESA balance is Ksh$balance. Transaction cost, Ksh0.00.',
    at,
  );

  SmsMessage _fromZiidi(DateTime at, String amount, String balance) => _mpesa(
    '${_receipt()} Confirmed.You have received Ksh$amount from ZIIDI on '
    '${_when(at, withAt: false)}. New M-PESA balance is Ksh$balance.',
    at,
  );

  SmsMessage _toShwari(
    DateTime at,
    String amount,
    String balance,
    String shwari,
  ) => _mpesa(
    '${_receipt()} Confirmed.Ksh$amount transferred to M-Shwari account on '
    '${_when(at)}. M-PESA balance is Ksh$balance .New M-Shwari saving '
    'account balance is Ksh$shwari. Transaction cost Ksh.0.00',
    at,
  );

  SmsMessage _toEtica(DateTime at, String amount, String balance) => _mpesa(
    '${_receipt()} Confirmed. Ksh$amount sent to ETICA CAPITAL LTD for '
    'account 000000M on ${_when(at)} New M-PESA balance is Ksh$balance. '
    'Transaction cost, Ksh0.00.',
    at,
  );

  SmsMessage _pochi(DateTime at, String amount, String from, String balance) =>
      _mpesa(
        '${_receipt()} Confirmed.You have received Ksh$amount from $from on '
        '${_when(at)} New Pochi balance is Ksh$balance.',
        at,
      );

  /// A month of M-Pesa with money moved to and from Ziidi and M-Shwari,
  /// one payment into Etica MMF, a sale into the Pochi, and Ziidi's value
  /// typed twice, which shows its returns. Each is added, as the person
  /// answered Add (decision 0026 item 5); with [answered] false, none is,
  /// so Activity asks about M-Shwari and Pochi.
  Future<FamilySeeded> seed({bool answered = true}) async {
    final transactions = DriftTransactionsRepository(db);
    final ingestor = SmsIngestor(
      accounts: DriftAccountsRepository(db),
      transactions: transactions,
      reviewInbox: DriftReviewInboxRepository(db, clock: () => familyNow),
      reads: MessageReadsRepository(db),
      parse: (packs, messages) async => parseAll(packs, messages),
    );
    final mpesa = institutionCatalogue.singleWhere((i) => i.id == 'mpesa');
    await ingestor.ingest(
      [
        _received(
          eat(2026, 9, 30, 17),
          '60,000.00',
          'EXAMPLE EMPLOYER LTD',
          '61,000.00',
        ),
        _toZiidi(eat(2026, 10, 1, 9), '20,000.00', '41,000.00'),
        _toShwari(eat(2026, 10, 5, 10), '5,000.00', '36,000.00', '18,000.00'),
        _paid(
          eat(2026, 10, 20, 18),
          '1,500.00',
          'EXAMPLE GROCERS',
          '34,500.00',
        ),
        _toZiidi(eat(2026, 11, 2, 9, 5), '10,000.00', '24,500.00'),
        _toEtica(eat(2026, 11, 6), '3,000.00', '21,500.00'),
        _fromZiidi(eat(2026, 11, 15, 16), '5,000.00', '26,500.00'),
        _paid(
          eat(2026, 11, 18, 13),
          '12,000.00',
          'EXAMPLE RENT AGENCY',
          '14,500.00',
        ),
        _toShwari(
          eat(2026, 11, 21, 8, 10),
          '2,000.00',
          '12,500.00',
          '20,000.00',
        ),
        _pochi(
          eat(2026, 11, 21, 9, 20),
          '1,200.00',
          'MARY ACHIENG 0711***000',
          '6,200.00',
        ),
      ],
      [mpesa],
    );

    if (!answered) return const FamilySeeded(ziidi: null, mshwari: null);
    final savings = DriftSavingsRepository(db);
    for (final product in [
      products.mshwari,
      products.ziidi,
      products.eticaMmf,
    ]) {
      await savings.add(product, at: familyNow);
    }
    await PochiAsk(db, ingestor: ingestor, mpesa: mpesa).add();
    final accounts = await db.select(db.accounts).get();
    final ziidi = accounts.singleWhere((a) => a.product == 'ziidi').id;
    final mshwari = accounts.singleWhere((a) => a.product == 'mshwari').id;
    final pocket = (await savings.account(ziidi))!.pockets.single.id;
    await savings.updateBalances(
      ziidi,
      balanceByPocket: {pocket: kes(20120)},
      at: eat(2026, 10, 31, 20),
    );
    await savings.updateBalances(
      ziidi,
      balanceByPocket: {pocket: kes(25300)},
      at: eat(2026, 11, 20, 20),
    );
    await savings.dispose();
    return FamilySeeded(ziidi: ziidi, mshwari: mshwari);
  }
}
