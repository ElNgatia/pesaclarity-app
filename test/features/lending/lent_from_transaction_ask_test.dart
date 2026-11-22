// Ask's "Who owes me?" counts money lent straight from a transaction, and
// what came back against it. Synthetic names and numbers only.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/time/clock.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/data/repositories/loan_links_repository.dart';
import 'package:pesaclarity/src/data/repositories/payees_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/domain/ask/context.dart';
import 'package:pesaclarity/src/domain/payees/payee_identifier.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';
import 'package:pesaclarity/src/features/ask/application/ask_providers.dart';

import '../../domain/fixtures.dart';
import '../../helpers/test_app.dart';

void main() {
  test('Who owes me? includes money lent from a transaction', () async {
    final db = openTestDatabase();
    final now = eat(2026, 11, 20, 10);
    final c = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(() => now),
        askReaderRuntimeOpenerProvider.overrideWithValue(null),
      ],
    );
    addTearDown(c.dispose);

    final mpesa = await db
        .into(db.accounts)
        .insert(
          AccountsCompanion.insert(
            name: 'M-Pesa',
            type: AccountType.mpesa,
            openingBalanceMinor: Value(kes(20000)),
            openingDate: eat(2026, 11, 1, 0),
          ),
        );
    final phone = PayeeIdentifier.phone('0700 000 003')!;
    final otieno = await DriftPayeesRepository(db)
        .name(phone, displayName: 'Test Otieno');
    final transactions = DriftTransactionsRepository(db);
    Future<int> money(int day, int shillings, TransactionDirection way) =>
        transactions.add(
          TransactionsCompanion.insert(
            accountId: mpesa,
            occurredAt: eat(2026, 11, day, 9),
            amountMinor: kes(shillings),
            direction: way,
            kind: Value(
              way == TransactionDirection.outflow
                  ? TransactionKind.sent
                  : TransactionKind.received,
            ),
            source: TransactionSource.sms,
            payeeId: Value(otieno),
            counterpartyKind: Value(phone.kind),
            counterpartyValue: Value(phone.value),
            receiptNo: Value('TASK$day'),
          ),
        );

    final links = DriftLoanLinksRepository(db);
    await links.lend(
      await money(5, 6000, TransactionDirection.outflow),
      person: 'Test Otieno',
      amountMinor: kes(6000),
      lentOn: CalendarDate(2026, 11, 5),
    );
    await links.paidBack(await money(12, 1500, TransactionDirection.inflow));

    final engine = await c.read(askEngineProvider.future);
    final turn = await engine.ask(
      'Who owes me?',
      context: AskContext.empty,
      now: now,
    );
    expect(turn.answer.figureMinor, kes(4500));
    expect(turn.answer.rows.single.title, 'Test Otieno');
  });
}
