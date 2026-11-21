// A made-up saver who pays into Chumz from M-Pesa, for the savings screens
// in the accessibility check. The paybill's name is public; the account
// codes, receipts, people, amounts and dates are invented. Not part of the
// marketing records (personal_records.dart), whose screenshots stay as
// they are.
import 'package:drift/drift.dart' show Value;
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/repositories/debts_repository.dart';
import 'package:pesaclarity/src/data/repositories/goals_repository.dart';
import 'package:pesaclarity/src/data/repositories/savings_repository.dart';
import 'package:pesaclarity/src/data/repositories/transactions_repository.dart';
import 'package:pesaclarity/src/domain/payees/payee_identifier.dart';
import 'package:pesaclarity/src/domain/savings/savings_account.dart';
import 'package:pesaclarity/src/domain/savings/savings_product.dart';
import 'package:pesaclarity/src/domain/savings/savings_prompt.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';

import '../domain/fixtures.dart';

/// Saturday 21 November 2026, 09:41 in Nairobi.
final savingsNow = eat(2026, 11, 21, 9, 41);
final savingsToday = CalendarDate.local(savingsNow);

const _nabo = 'NABO CAPITAL LTD C2B';

/// What [SavingsRecords.seed] made.
class SavingsSeeded {
  const SavingsSeeded({required this.mpesa, required this.todaysPayment});

  final int mpesa;

  /// The payment to Chumz this morning, which the question is asked under.
  final int todaysPayment;
}

class SavingsRecords {
  SavingsRecords(this.db);

  final AppDatabase db;
  var _receipts = 0;

  /// M-Pesa with payments to Chumz under two account codes, money back from
  /// it on 10 Nov and a few other days' spending and money in, all read
  /// before Chumz is added.
  Future<SavingsSeeded> seed() async {
    final mpesa = await db
        .into(db.accounts)
        .insert(
          AccountsCompanion.insert(
            name: 'M-Pesa',
            type: AccountType.mpesa,
            openingBalanceMinor: Value(kes(15000)),
            openingDate: eat(2026, 9, 1),
            institutionId: const Value('mpesa'),
          ),
        );
    Future<int> category(String key) async => (await (db.select(
      db.categories,
    )..where((c) => c.key.equals(key))).getSingle()).id;

    TransactionsCompanion paid(DateTime at, int shillings, String code) {
      final receipt = 'TKS${(++_receipts).toString().padLeft(7, '0')}';
      return TransactionsCompanion.insert(
        accountId: mpesa,
        occurredAt: at,
        amountMinor: kes(shillings),
        direction: TransactionDirection.outflow,
        kind: const Value(TransactionKind.paybill),
        counterpartyKind: const Value(PayeeIdentifierKind.paybill),
        counterpartyValue: Value(PayeeIdentifier.paybill(_nabo, code)!.value),
        counterpartyName: const Value(_nabo),
        receiptNo: Value(receipt),
        source: TransactionSource.sms,
        messageHash: Value('hash-$receipt'),
        dedupeKey: Value('$receipt|${kes(shillings)}'),
      );
    }

    TransactionsCompanion other(
      DateTime at,
      int shillings,
      String name, {
      required TransactionDirection direction,
      TransactionKind kind = TransactionKind.sent,
      int? categoryId,
    }) {
      final receipt = 'TKS${(++_receipts).toString().padLeft(7, '0')}';
      return TransactionsCompanion.insert(
        accountId: mpesa,
        occurredAt: at,
        amountMinor: kes(shillings),
        direction: direction,
        kind: Value(kind),
        counterpartyName: Value(name),
        categoryOverrideId: Value(categoryId),
        receiptNo: Value(receipt),
        source: TransactionSource.sms,
        messageHash: Value('hash-$receipt'),
        dedupeKey: Value('$receipt|${kes(shillings)}'),
      );
    }

    final transactions = DriftTransactionsRepository(db);
    await transactions.addNew([
      paid(eat(2026, 10, 2, 8), 2000, 'CH12345'),
      paid(eat(2026, 10, 20, 8), 2500, 'CH67890'),
      paid(eat(2026, 11, 1, 8), 1065, 'CH12345'),
      other(
        eat(2026, 11, 10, 15),
        1000,
        'NABO CAPITAL LTD',
        direction: TransactionDirection.inflow,
        kind: TransactionKind.received,
      ),
      other(
        eat(2026, 11, 20, 18),
        1075,
        'Naivas Juja City',
        direction: TransactionDirection.outflow,
        kind: TransactionKind.till,
        categoryId: await category('groceries'),
      ),
      other(
        eat(2026, 11, 20, 9),
        180,
        'Wanjiku Kamau',
        direction: TransactionDirection.inflow,
        kind: TransactionKind.received,
        categoryId: await category('gifts_received'),
      ),
      other(
        eat(2026, 11, 21, 8, 30),
        450,
        'Mama Mboga',
        direction: TransactionDirection.outflow,
        kind: TransactionKind.till,
        categoryId: await category('groceries'),
      ),
      paid(eat(2026, 11, 21, 9, 12), 50, 'CH12345'),
    ]);
    final today = await (db.select(
      db.transactions,
    )..where((t) => t.amountMinor.equals(kes(50)))).getSingle();
    return SavingsSeeded(mpesa: mpesa, todaysPayment: today.id);
  }

  /// Adds Chumz as its sheet would, from the question under today's
  /// payment: Christmas locked until 15 Dec, School fees open. With
  /// [balances], the money back goes to School fees and the balances Chumz
  /// shows are typed, which shows 85 interest on Christmas; a goal of the
  /// person's is then saved in each.
  Future<int> addChumz(SavingsSeeded seeded, {bool balances = true}) async {
    final savings = DriftSavingsRepository(db);
    final added = await savings.add(
      chumz,
      at: savingsNow,
      pockets: [
        SavingsPocketDraft(
          code: 'CH12345',
          name: 'Christmas',
          lockedUntil: CalendarDate(2026, 12, 15).startInstant,
        ),
        const SavingsPocketDraft(code: 'CH67890', name: 'School fees'),
      ],
      promptedTransactionId: seeded.todaysPayment,
    );
    if (balances) {
      final account = (await savings.account(added.accountId))!;
      final christmas = account.pockets.firstWhere((p) => p.code == 'CH12345');
      final school = account.pockets.firstWhere((p) => p.code == 'CH67890');
      for (final e in account.unassigned) {
        await savings.assignEntry(e.transactionId, school.id);
      }
      await savings.updateBalances(
        added.accountId,
        balanceByPocket: {christmas.id: kes(3200), school.id: kes(1500)},
        at: savingsNow.add(const Duration(minutes: 1)),
      );
      final goals = DriftGoalsRepository(db);
      final christmasGoal = await goals.add(
        name: 'Christmas',
        targetMinor: kes(10000),
      );
      await goals.setPocket(christmasGoal, christmas.id);
      final schoolGoal = await goals.add(
        name: 'School fees',
        targetMinor: kes(20000),
      );
      await goals.setPocket(schoolGoal, school.id);
      await goals.add(
        name: 'Emergency fund',
        targetMinor: kes(50000),
        savedMinor: kes(20000),
      );
      await goals.add(
        name: 'New laptop',
        targetMinor: kes(60000),
        savedMinor: kes(21000),
      );
      final debts = DriftDebtsRepository(db);
      final bank = await debts.add(
        DebtsCompanion.insert(
          lender: 'Bank loan',
          type: DebtType.bankLoan,
          startingBalanceMinor: kes(120000),
          annualRateBasisPoints: const Value(1300),
          minimumPaymentMinor: const Value(1500000),
        ),
      );
      await debts.confirmBalance(bank, kes(82300), eat(2026, 11, 1));
    }
    await savings.dispose();
    return added.accountId;
  }

  /// The account as the update sheet gets it, with both goals.
  Future<SavingsAccountSummary> account(int accountId) async {
    final savings = DriftSavingsRepository(db);
    final account = (await savings.account(accountId))!;
    await savings.dispose();
    return account;
  }
}
