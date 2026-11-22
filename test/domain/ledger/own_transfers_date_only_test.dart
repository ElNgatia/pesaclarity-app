import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/enums.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_entry.dart';
import 'package:pesaclarity/src/domain/ledger/own_accounts.dart';
import 'package:pesaclarity/src/domain/ledger/own_transfers.dart';

import '../fixtures.dart';

const _kcb = 21;
const _mpesa = 22;

// A KCB statement prints dates and no times, so its rows fall at midnight
// East Africa Time. Made-up numbers: 0700000001 is the person's own M-Pesa.
LedgerEntry _statementSend(
  DateTime at, {
  String phone = '0700000001',
  TransactionSource source = TransactionSource.statement,
}) => LedgerEntry(
  id: 1,
  accountId: _kcb,
  occurredAt: at,
  amountMinor: kes(2500),
  direction: TransactionDirection.outflow,
  kind: TransactionKind.sent,
  currency: 'KES',
  feeMinor: kes(30),
  source: source,
  counterpartyKind: PayeeIdentifierKind.phone,
  counterpartyValue: phone,
);

LedgerEntry _mpesaIn(DateTime at) =>
    inflow(id: 2, accountId: _mpesa, at: at, amount: kes(2500));

final _own = OwnAccounts([
  const OwnAccount(id: _kcb, institutionId: 'kcb'),
  const OwnAccount(id: _mpesa, reference: '0700000001', institutionId: 'mpesa'),
]);

void main() {
  final midnight = eat(2026, 9, 4, 0);

  test('a statement row at midnight East Africa Time has only a date', () {
    expect(isDateOnly(_statementSend(midnight)), isTrue);
    expect(isDateOnly(_statementSend(eat(2026, 9, 4, 14))), isFalse);
    expect(
      isDateOnly(_statementSend(midnight, source: TransactionSource.sms)),
      isFalse,
    );
  });

  test('a date-only side counts as its whole day', () {
    final send = _statementSend(midnight);
    expect(dayAwareGap(send, _mpesaIn(eat(2026, 9, 4, 14, 15))), Duration.zero);
    expect(
      dayAwareGap(_mpesaIn(eat(2026, 9, 5, 0, 20)), send),
      const Duration(minutes: 20),
    );
    expect(
      dayAwareGap(send, _mpesaIn(eat(2026, 9, 3, 23))),
      const Duration(hours: 1),
    );
  });

  test('a statement send to an own number pairs with M-Pesa that day', () {
    expect(
      findOwnTransfers([
        _statementSend(midnight),
        _mpesaIn(eat(2026, 9, 4, 14, 15)),
      ], own: _own),
      [const TransferPair(1, 2)],
    );
  });

  test('but not on another day, or to another number', () {
    expect(
      findOwnTransfers([
        _statementSend(midnight),
        _mpesaIn(eat(2026, 9, 5, 14, 15)),
      ], own: _own),
      isEmpty,
    );
    expect(
      findOwnTransfers([
        _statementSend(midnight, phone: '0711111111'),
        _mpesaIn(eat(2026, 9, 4, 14, 15)),
      ], own: _own),
      isEmpty,
    );
  });
}
