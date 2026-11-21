import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/time/clock.dart';
import 'package:pesaclarity/src/data/database/app_database.dart'
    hide ParserPack;
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/data/repositories/balances_repair.dart';
import 'package:pesaclarity/src/data/repositories/institutions_repository.dart';
import 'package:pesaclarity/src/data/repositories/journal_repository.dart';
import 'package:pesaclarity/src/features/accounts/domain/institution.dart';
import 'package:pesaclarity/src/features/balances/application/balances_providers.dart';
import 'package:pesaclarity/src/features/sms/application/read_again.dart';
import 'package:pesaclarity/src/features/sms/application/sms_capture_providers.dart';
import 'package:pesaclarity/src/features/sms/data/sms_source.dart';
import 'package:ujumbe/ujumbe.dart';

import '../helpers/fake_sms_source.dart';
import '../helpers/test_app.dart';

// An upgrade replayed on made-up messages: three months of one person's
// M-Pesa (sent, paybill, till, received, a Fuliza draw and its repayment,
// fees, a reversal) and KCB, with money from KCB into M-Pesa. Each step the
// app runs on start must leave every account as its last message reports.
DateTime _eat(int m, int d, int h, [int min = 0, int s = 5]) =>
    DateTime.utc(2026, m, d, h - 3, min, s);

SmsMessage _m(String body, DateTime at) =>
    SmsMessage(sender: 'MPESA', body: body, receivedAt: at);
SmsMessage _k(String body, DateTime at) =>
    SmsMessage(sender: 'KCB', body: body, receivedAt: at);

final _inbox = [
  _m(
    'TJB0000001 Confirmed.You have received Ksh5,000.00 from JOHN KAMAU '
    '0700***002 on 1/8/26 at 8:00 AM  New M-PESA balance is Ksh15,000.00.',
    _eat(8, 1, 8),
  ),
  _m(
    'TJB0000002 Confirmed. Ksh1,500.00 sent to JANE DOE 0700***001 on 2/8/26 '
    'at 9:15 AM. New M-PESA balance is Ksh13,485.00. Transaction cost, '
    'Ksh15.00. Amount you can transact within the day is 498,500.00.',
    _eat(8, 2, 9, 15),
  ),
  _m(
    'TJB0000003 Confirmed. Ksh1,200.00 sent to EXAMPLE POWER LTD for account '
    '1234567890 on 5/8/26 at 11:30 AM New M-PESA balance is Ksh12,270.00. '
    'Transaction cost, Ksh15.00.Amount you can transact within the day is '
    '497,300.00.',
    _eat(8, 5, 11, 30),
  ),
  _m(
    'TJB0000004 Confirmed. Ksh350.00 paid to EXAMPLE GROCERS. on 7/8/26 at '
    '1:45 PM.New M-PESA balance is Ksh11,920.00. Transaction cost, Ksh0.00. '
    'Amount you can transact within the day is 496,950.00.',
    _eat(8, 7, 13, 45),
  ),
  _k(
    'Dear Customer, KES 3,000.00 has been debited from your account ****0001 '
    'on 15/08/2026 at 10:00. Transaction Ref: KCB0000000101. Your available '
    'balance is KES 17,000.00.',
    _eat(8, 15, 10),
  ),
  _m(
    'TJB0000006 Confirmed.You have received Ksh3,000.00 from EXAMPLE BANK 1 '
    '522522 on 15/8/26 at 10:01 AM New M-PESA balance is Ksh14,920.00.',
    _eat(8, 15, 10, 1),
  ),
  // Paying 15,000 with 14,920 in M-Pesa: Fuliza covers 80.
  _m(
    'TJB0000007 Confirmed. Ksh15,000.00 sent to JANE DOE 0700***001 on '
    '20/8/26 at 12:00 PM. New M-PESA balance is Ksh0.00. Transaction cost, '
    'Ksh0.00. Amount you can transact within the day is 483,500.00.',
    _eat(8, 20, 12),
  ),
  _m(
    'TJB0000008 Confirmed. Fuliza M-Pesa amount is Ksh 80.00. Access Fee '
    'charged Ksh 0.80. Total Fuliza M-Pesa outstanding amount is Ksh 80.80 '
    'due on 19/9/26. To check daily charges, Dial *000*0#OK Select Query '
    'Charges',
    _eat(8, 20, 12, 0, 35),
  ),
  // Money in repays Fuliza first: both messages print what is left.
  _m(
    'TJB0000009 Confirmed.You have received Ksh2,000.00 from JOHN KAMAU '
    '0700***002 on 25/8/26 at 8:00 AM  New M-PESA balance is Ksh1,919.20.',
    _eat(8, 25, 8),
  ),
  _m(
    'TJB0000010 Confirmed. Ksh 80.80 from your M-PESA has been used to fully '
    'pay your outstanding Fuliza M-PESA. Available Fuliza M-PESA limit is '
    'Ksh 2,000.00. M-PESA balance is Ksh1,919.20.',
    _eat(8, 25, 8, 0, 20),
  ),
  _m(
    'TJB0000011 Confirmed.on 1/9/26 at 5:10 PMWithdraw Ksh1,000.00 from '
    '123456 - EXAMPLE AGENT SHOP NAIROBI New M-PESA balance is Ksh890.20. '
    'Transaction cost, Ksh29.00.',
    _eat(9, 1, 17, 10),
  ),
  _m(
    'TJB0000012 confirmed.You bought Ksh100.00 of airtime on 3/9/26 at 7:00 '
    'PM.New M-PESA balance is Ksh790.20. Transaction cost, Ksh0.00.',
    _eat(9, 3, 19),
  ),
  _m(
    'TJB0000013 Confirmed. Ksh300.00 sent to MARY  ATIENO on 5/9/26 at 9:20 '
    'AM. New M-PESA balance is Ksh490.20. Transaction cost, Ksh0.00. Amount '
    'you can transact within the day is 498,200.00.',
    _eat(9, 5, 9, 20),
  ),
  _m(
    'TJB0000014 Confirmed. Reversal of transaction TJB0000013 has been '
    'successfully reversed  on 5/9/26 at 8:00 PM and Ksh300.00 is credited '
    'to your M-PESA account. New M-PESA account balance is Ksh790.20.',
    _eat(9, 5, 20),
  ),
  _m(
    'TJB0000015 Confirmed.You have received Ksh20,000.00 from EXAMPLE SACCO '
    'on 30/9/26 at 8:05 AM New M-PESA balance is Ksh20,790.20.',
    _eat(9, 30, 8, 5),
  ),
  _m(
    'TJB0000016 Confirmed. Ksh2,500.00 sent to EXAMPLE WATER LTD for account '
    '555 on 2/10/26 at 11:30 AM New M-PESA balance is Ksh18,275.20. '
    'Transaction cost, Ksh15.00.Amount you can transact within the day is '
    '497,300.00.',
    _eat(10, 2, 11, 30),
  ),
  _k(
    'Dear Customer, KES 2,000.00 has been debited from your account ****0001 '
    'on 08/10/2026 at 15:20. Transaction Ref: KCB0000000102. Your available '
    'balance is KES 15,000.00.',
    _eat(10, 8, 15, 20),
  ),
  _m(
    'TJB0000017 Confirmed. Ksh650.00 paid to EXAMPLE GROCERS. on 10/10/26 at '
    '1:45 PM.New M-PESA balance is Ksh17,625.20. Transaction cost, Ksh0.00. '
    'Amount you can transact within the day is 496,950.00.',
    _eat(10, 10, 13, 45),
  ),
];

/// What the last messages say each account holds.
const _mpesaNow = 1762520;
const _kcbNow = 1500000;

void main() {
  late AppDatabase db;
  late FakeSmsSource source;
  final now = DateTime.utc(2026, 10, 20, 9);
  final selected = [
    for (final id in ['mpesa', 'kcb'])
      institutionCatalogue.singleWhere((i) => i.id == id),
  ];

  setUp(() async {
    db = openTestDatabase();
    source = FakeSmsSource(inbox: _inbox);
    addTearDown(source.close);
    for (final i in selected) {
      await DriftInstitutionsRepository(db).setSelected(i.id, selected: true);
    }
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        smsSourceProvider.overrideWithValue(source),
        clockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<Map<String, (int, int, int)>> shown(ProviderContainer c) async {
    c.invalidate(balancesOverviewProvider);
    final o = await c.read(balancesOverviewProvider.future);
    return {
      for (final a in o.accounts)
        a.account.name: (a.heldMinor, a.walletMinor, a.fulizaOwedMinor),
    };
  }

  test('every step the app runs on start leaves the balances as the '
      'messages report them', () async {
    final c = container();
    await c.read(smsScanServiceProvider).scan(selected);
    final first = await shown(c);
    expect(first['M-Pesa'], (_mpesaNow, _mpesaNow, 0), reason: '$first');
    expect(first['KCB'], (_kcbNow, _kcbNow, 0), reason: '$first');
    final rows = (await db.select(db.transactions).get()).length;

    final steps = <String, Future<void> Function()>{
      'pairing history (version 2)': () =>
          c.read(pairHistoryOnceProvider.future),
      'the catch-up scan on return to the front': () async {
        await c.read(smsScanServiceProvider).scan(selected);
      },
      'Read messages again': () =>
          c.read(readAgainControllerProvider.notifier).readAgain(),
      'a rebuild marked after Clear data': () =>
          JournalRepository.markForRebuild(db),
      'a full rebuild': () async {
        await JournalRepository(db).rebuild();
      },
      'the repair on update, run again': () async {
        await repairBalances(db);
      },
    };
    for (final MapEntry(key: step, value: run) in steps.entries) {
      await run();
      expect(await shown(c), first, reason: 'after $step');
      expect(
        await db.select(db.transactions).get(),
        hasLength(rows),
        reason: 'after $step',
      );
    }
    expect(await JournalRepository(db).unbalanced(), isEmpty);
  });
}
