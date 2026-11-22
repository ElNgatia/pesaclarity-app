import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/enums.dart';
import 'package:pesaclarity/src/domain/firefly/firefly_mapping.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_entry.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_role.dart';

const _names = FireflyNames(spaceName: 'Personal', personal: true);
const _mpesa = FireflyMoneyAccount(
  id: 1,
  name: 'M-Pesa',
  type: AccountType.mpesa,
  currency: 'KES',
);
const _bank = FireflyMoneyAccount(
  id: 2,
  name: 'KCB',
  type: AccountType.bank,
  currency: 'KES',
);
const _dollars = FireflyMoneyAccount(
  id: 3,
  name: 'Dollar account',
  type: AccountType.bank,
  currency: 'USD',
);
final _at = DateTime.utc(2026, 11, 3, 11, 5);

LedgerEntry _entry(
  TransactionKind kind,
  TransactionDirection direction,
  int amount, {
  int id = 7,
  int account = 1,
  int fee = 0,
  CategoryType? categoryType,
  int? categoryId,
  int? payeeId,
  String? payeeName,
  int? pairId,
  String currency = 'KES',
}) => LedgerEntry(
  id: id,
  accountId: account,
  occurredAt: _at,
  amountMinor: amount,
  direction: direction,
  kind: kind,
  feeMinor: fee,
  currency: currency,
  categoryType: categoryType,
  categoryId: categoryId ?? (categoryType == null ? null : 9),
  payeeId: payeeId ?? (payeeName == null ? null : 4),
  payeeName: payeeName,
  transferPairId: pairId,
);

/// [e]'s parts, with the journal moving its account as the entry reads
/// alone, unless told otherwise.
List<FireflyPart> _parts(
  LedgerEntry e, {
  FireflyMoneyAccount account = _mpesa,
  int? money,
  int fuliza = 0,
  int borrowed = 0,
  int gap = 0,
  LedgerEntry? partner,
  FireflyMoneyAccount? partnerAccount,
  String? category,
  String? receipt,
}) => fireflyParts(
  FireflyTransactionFacts(
    entry: e,
    account: account,
    journalMoneyMinor:
        money ?? (e.isInflow ? e.amountMinor : -e.amountMinor) - e.feeMinor,
    journalFulizaMinor: fuliza,
    journalBorrowedMinor: borrowed,
    partner: partner,
    partnerAccount: partnerAccount,
    categoryName: category,
    receipt: receipt,
    gapMinor: gap,
  ),
  _names,
);

void main() {
  test('external ids are stable and say the space', () {
    expect(fireflyExternalId('personal', 42), 'pesaclarity:personal:42');
    expect(fireflyExternalId('shop1', 42, 'fee'), 'pesaclarity:shop1:42:fee');
    expect(fireflyExternalPrefix('shop1'), 'pesaclarity:shop1:');
  });

  test('spending: a withdrawal to the payee, the fee its own to Fees', () {
    final e = _entry(
      TransactionKind.sent,
      TransactionDirection.outflow,
      50000,
      fee: 700,
      categoryType: CategoryType.expense,
      payeeName: 'Mama Lunch',
    );
    expect(roleOf(e), LedgerRole.spending);
    final parts = _parts(e, category: 'Food', receipt: 'SKL4X2Y9ZQ');
    expect(parts, hasLength(2));
    final main = parts.first;
    expect(main.suffix, '');
    expect(main.type, FireflyPartType.withdrawal);
    expect(main.source.key, 'money:1');
    expect(main.destination.kind, FireflyAccountKind.expense);
    expect(main.destination.name, 'Mama Lunch');
    expect(main.category, 'Food');
    expect(main.notes, 'M-Pesa SKL4X2Y9ZQ');
    expect(main.tags, ['pesaclarity', 'Personal']);
    final fee = parts.last;
    expect(fee.suffix, 'fee');
    expect(fee.destination.name, fireflyFees);
    expect(fee.amountMinor, 700);
  });

  test('income: a deposit from the payer', () {
    final e = _entry(
      TransactionKind.bank,
      TransactionDirection.inflow,
      5000000,
      account: 2,
      categoryType: CategoryType.income,
      payeeName: 'Employer',
    );
    final [main] = _parts(e, account: _bank, category: 'Salary');
    expect(main.type, FireflyPartType.deposit);
    expect(main.source.kind, FireflyAccountKind.revenue);
    expect(main.source.name, 'Employer');
    expect(main.destination.key, 'money:2');
  });

  test('a fee and tax are withdrawals', () {
    final charge = _entry(
      TransactionKind.charge,
      TransactionDirection.outflow,
      3000,
    );
    expect(roleOf(charge), LedgerRole.fee);
    final [fee] = _parts(charge);
    expect(fee.destination.name, fireflyFees);
    expect(fee.category, fireflyFees);

    final tax = _entry(
      TransactionKind.paybill,
      TransactionDirection.outflow,
      10000,
      categoryType: CategoryType.tax,
    );
    expect(roleOf(tax), LedgerRole.tax);
    expect(_parts(tax).single.destination.name, 'Tax');
  });

  test('money in from someone not named yet is tagged to name', () {
    final e = _entry(
      TransactionKind.received,
      TransactionDirection.inflow,
      70000,
    );
    expect(roleOf(e), LedgerRole.awaitingPayee);
    final [main] = _parts(e);
    expect(main.source.name, notNamedYet);
    expect(main.tags, contains(fireflyToNameTag));

    // Named later: the same transaction now comes from the payee.
    final named = _entry(
      TransactionKind.received,
      TransactionDirection.inflow,
      70000,
      categoryType: CategoryType.income,
      payeeName: 'Aunt',
    );
    final [after] = _parts(named);
    expect(after.source.name, 'Aunt');
    expect(after.tags, isNot(contains(fireflyToNameTag)));
    expect(fireflyPartsHash([after]), isNot(fireflyPartsHash([main])));
  });

  test('a reversal is the opposite kind, noted', () {
    final refund = _entry(
      TransactionKind.reversal,
      TransactionDirection.inflow,
      2000,
      payeeName: 'Shop',
    );
    expect(roleOf(refund), LedgerRole.reversal);
    final [main] = _parts(refund);
    expect(main.type, FireflyPartType.deposit);
    expect(main.notes, 'Reversal');
  });

  test('a Fuliza draw comes from the Fuliza liability; its fee adds to it', () {
    final draw = _entry(
      TransactionKind.fulizaDraw,
      TransactionDirection.inflow,
      80000,
      fee: 800,
    );
    expect(roleOf(draw), LedgerRole.borrowing);
    final parts = _parts(draw, money: 80000, fuliza: 80800);
    expect(parts, hasLength(2));
    expect(parts.first.type, FireflyPartType.deposit);
    expect(parts.first.source.key, 'fuliza:1');
    expect(parts.first.source.kind, FireflyAccountKind.liability);
    expect(parts.first.source.liabilityType, 'loan');
    expect(parts.last.source.key, 'fuliza:1');
    expect(parts.last.destination.name, fireflyFees);
    expect(fireflyDeltas(parts), {'money:1': 80000, 'fuliza:1': 80800});
  });

  test('a repayment goes to the liability; what the balances add is sent', () {
    final repay = _entry(
      TransactionKind.fulizaRepayment,
      TransactionDirection.outflow,
      80000,
    );
    expect(roleOf(repay), LedgerRole.debtRepayment);
    // The journal says 808 was owed: 8 more of charges.
    final parts = _parts(repay, money: -80800, fuliza: -80800);
    expect(parts.first.destination.key, 'fuliza:1');
    expect(fireflyDeltas(parts), {'money:1': -80800, 'fuliza:1': -80800});
    expect(parts.last.suffix, 'repay');
  });

  test('Fuliza not tracked: no liability; the draw comes from outside and '
      'the repayment goes there, M-Pesa moving exactly as before', () {
    final draw = _entry(
      TransactionKind.fulizaDraw,
      TransactionDirection.inflow,
      80000,
      fee: 800,
    );
    final repay = _entry(
      TransactionKind.fulizaRepayment,
      TransactionDirection.outflow,
      80000,
      id: 8,
    );
    final drawn = fireflyWithoutFuliza(
      _parts(draw, money: 80000, fuliza: 80800),
    );
    final repaid = fireflyWithoutFuliza(
      _parts(repay, money: -80800, fuliza: -80800),
    );
    final all = [...drawn, ...repaid];
    for (final p in all) {
      for (final a in p.accounts) {
        expect(a.kind, isNot(FireflyAccountKind.liability), reason: '$p');
        expect(a.name, isNot(contains('Fuliza')), reason: '$p');
      }
      expect(p.description, isNot(contains('Fuliza')), reason: '$p');
    }
    // The access fee only added to what was owed: nothing own moved, so
    // it is left out, and paid with the repayment.
    expect(drawn, hasLength(1));
    expect(drawn.single.type, FireflyPartType.deposit);
    expect(drawn.single.source, FireflyAccountSpec.revenue(fireflyOverdraft));
    expect(
      repaid.first.destination,
      FireflyAccountSpec.expense(fireflyOverdraft),
    );
    expect(fireflyDeltas(drawn), {'money:1': 80000});
    expect(fireflyDeltas(repaid), {'money:1': -80800});
  });

  test('a loan from a lender is a liability named after it', () {
    final loan = _entry(
      TransactionKind.received,
      TransactionDirection.inflow,
      300000,
      categoryType: CategoryType.debt,
      payeeName: 'M-Shwari',
    );
    final [main] = _parts(loan, borrowed: 300000);
    expect(main.source.key, 'lender:M-Shwari:KES');
    expect(main.source.name, 'M-Shwari');
    final repaid = _entry(
      TransactionKind.paybill,
      TransactionDirection.outflow,
      100000,
      categoryType: CategoryType.debt,
      payeeName: 'M-Shwari',
    );
    final [back] = _parts(repaid, borrowed: -100000);
    expect(back.destination.key, 'lender:M-Shwari:KES');
    expect(fireflyDeltas([main, back]), {
      'money:1': 200000,
      'lender:M-Shwari:KES': 200000,
    });
  });

  test('own transfers: one transfer from the money out, none from the in', () {
    final out = _entry(
      TransactionKind.bank,
      TransactionDirection.outflow,
      1000000,
      account: 2,
      fee: 5000,
      categoryType: CategoryType.transfer,
      pairId: 8,
    );
    final into = _entry(
      TransactionKind.received,
      TransactionDirection.inflow,
      1000000,
      id: 8,
      categoryType: CategoryType.transfer,
      pairId: 7,
    );
    final parts = _parts(
      out,
      account: _bank,
      partner: into,
      partnerAccount: _mpesa,
    );
    expect(parts.first.type, FireflyPartType.transfer);
    expect(parts.first.source.key, 'money:2');
    expect(parts.first.destination.key, 'money:1');
    expect(parts.last.suffix, 'fee');
    expect(_parts(into, partner: out, partnerAccount: _bank), isEmpty);
    // Not yet matched: through Money in transit.
    final alone = _entry(
      TransactionKind.bank,
      TransactionDirection.outflow,
      1000000,
      account: 2,
      categoryType: CategoryType.transfer,
    );
    expect(_parts(alone, account: _bank).single.destination.key, 'transit:KES');
  });

  test('less arrived than left: the rest is a charge on the way', () {
    final out = _entry(
      TransactionKind.bank,
      TransactionDirection.outflow,
      100000,
      account: 2,
      categoryType: CategoryType.transfer,
      pairId: 8,
    );
    final into = _entry(
      TransactionKind.received,
      TransactionDirection.inflow,
      99000,
      id: 8,
      categoryType: CategoryType.transfer,
      pairId: 7,
    );
    final parts = _parts(
      out,
      account: _bank,
      partner: into,
      partnerAccount: _mpesa,
    );
    expect(parts.first.amountMinor, 99000);
    expect(parts.last.suffix, 'lost');
    expect(fireflyDeltas(parts), {'money:2': -100000, 'money:1': 99000});
  });

  test('another currency: a transfer with the foreign amount', () {
    final out = _entry(
      TransactionKind.bank,
      TransactionDirection.outflow,
      1305000,
      account: 2,
      categoryType: CategoryType.transfer,
      pairId: 8,
    );
    final into = _entry(
      TransactionKind.bank,
      TransactionDirection.inflow,
      10000,
      id: 8,
      account: 3,
      currency: 'USD',
      categoryType: CategoryType.transfer,
      pairId: 7,
    );
    final [main] = _parts(
      out,
      account: _bank,
      partner: into,
      partnerAccount: _dollars,
    );
    expect(main.currency, 'KES');
    expect(main.foreignAmountMinor, 10000);
    expect(main.foreignCurrency, 'USD');
    expect(fireflyDeltas([main]), {'money:2': -1305000, 'money:3': 10000});
  });

  test('saving with no account of its own goes to Savings', () {
    final e = _entry(
      TransactionKind.paybill,
      TransactionDirection.outflow,
      20000,
      categoryType: CategoryType.savings,
    );
    expect(roleOf(e), LedgerRole.saving);
    final [main] = _parts(e);
    expect(main.type, FireflyPartType.transfer);
    expect(main.destination.key, 'savings:KES');
    expect(main.destination.role, 'savingAsset');
  });

  test('a balance correction sends what it changed', () {
    final e = _entry(
      TransactionKind.correction,
      TransactionDirection.inflow,
      4000,
    );
    expect(roleOf(e), LedgerRole.correction);
    final [main] = _parts(e, money: 4000);
    expect(main.suffix, '');
    expect(main.source.name, fireflyBalanceCorrection);
    expect(main.category, fireflyBalanceCorrection);
  });

  test('a reported balance the records did not reach is sent as a gap', () {
    final e = _entry(
      TransactionKind.till,
      TransactionDirection.outflow,
      1000,
      categoryType: CategoryType.expense,
      payeeName: 'Shop',
    );
    final parts = _parts(e, gap: -2500);
    expect(parts.last.suffix, 'gap');
    expect(parts.last.destination.name, fireflyNotYetSorted);
    expect(fireflyDeltas(parts), {'money:1': -3500});
  });

  test("a space's own accounts carry its name; Personal's do not", () {
    const shop = FireflyNames(spaceName: 'Shop', personal: false);
    expect(shop.asset(_mpesa).name, 'M-Pesa · Shop');
    expect(_names.asset(_mpesa).name, 'M-Pesa');
    expect(_names.fuliza(_mpesa).name, 'Fuliza');
    expect(_names.asset(_mpesa).role, 'defaultAsset');
    const cash = FireflyMoneyAccount(
      id: 5,
      name: 'Cash',
      type: AccountType.cash,
      currency: 'KES',
    );
    expect(cash.role, 'cashWalletAsset');
  });

  test('amounts and dates as Firefly III reads them', () {
    expect(fireflyAmount(45000, 2), '450.00');
    expect(fireflyAmount(5, 2), '0.05');
    expect(fireflyAmount(-25000, 2), '-250.00');
    expect(fireflyAmount(1500, 0), '1500');
    expect(fireflyMinor('450.000000000000', 2), 45000);
    expect(fireflyMinor('-1100', 2), -110000);
    expect(fireflyMinor('0.005', 2), 1);
    expect(fireflyMinor('abc', 2), isNull);
    expect(
      fireflyDate(_at, const Duration(hours: 3)),
      '2026-11-03T14:05:00+03:00',
    );
  });

  test('reads the answers Firefly III 6.7.9 gave', () {
    Map<String, Object?> fixture(String name) =>
        jsonDecode(File('test/fixtures/firefly/$name.json').readAsStringSync())
            as Map<String, Object?>;
    final split =
        ((fixture('transaction_withdrawal')['data']! as Map)['attributes']!
                as Map)['transactions']!
            as List;
    final first = split.first as Map;
    expect(fireflyMinor(first['amount'] as String, 2), 47000);
    expect(first['external_id'], 'pesaclarity:sp1:1');
    final liability =
        (fixture('account_liability')['data']! as Map)['attributes']! as Map;
    // A liability the person owes shows as a negative balance.
    expect(fireflyMinor(liability['current_balance'] as String, 2), isNegative);
  });
}
