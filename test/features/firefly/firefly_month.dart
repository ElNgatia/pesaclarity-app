// A made-up month for the Firefly III tests: two spaces with M-Pesa, a bank,
// Cash and a dollar account, spending, income, own transfers, a Fuliza draw
// and its repayment, fees, money in from someone not named, and then an
// edit, a delete and a move between the spaces. No real names, numbers or
// messages.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/repositories/space_move_repository.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/features/firefly/data/firefly_space_store.dart';

/// East Africa Time, as the app's dates are read.
DateTime eat(int y, int m, int d, [int h = 9, int min = 0]) =>
    DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 3));

/// Send from: 1 January 2026, in East Africa Time.
final fireflyFrom = DateTime.utc(2025, 12, 31, 21);

/// The two spaces of the month and their databases.
class FireflyMonth {
  FireflyMonth._(
    this.personal,
    this.business,
    this.personalDb,
    this.businessDb,
  );

  /// Spaces named apart, so runs against one Firefly III never meet.
  static Future<FireflyMonth> create({String tag = ''}) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final personalDb = AppDatabase(NativeDatabase.memory());
    final businessDb = AppDatabase(NativeDatabase.memory());
    await businessDb.becomeSpace(SpaceKind.business);
    final suffix = tag.isEmpty ? '' : ' $tag';
    final id = tag.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    return FireflyMonth._(
      Space(id: 'home$id', name: 'Home$suffix', kind: SpaceKind.household),
      Space(
        id: 'shop$id',
        name: 'Green Basket Grocers$suffix',
        kind: SpaceKind.business,
      ),
      personalDb,
      businessDb,
    );
  }

  final Space personal;
  final Space business;
  final AppDatabase personalDb;
  final AppDatabase businessDb;

  late int mpesa;
  late int kcb;
  late int cash;
  late int dollars;
  late int naivas;
  late int employer;
  late int food;
  late int salary;
  late int shopMpesa;

  /// Ids of transactions the later steps change.
  late int groceries;
  late int lunch;
  late int sale;

  Future<void> close() async {
    await personalDb.close();
    await businessDb.close();
  }

  Future<int> _account(
    AppDatabase db,
    String name,
    AccountType type, {
    String currency = 'KES',
    int opening = 0,
    String? institution,
  }) => db
      .into(db.accounts)
      .insert(
        AccountsCompanion.insert(
          name: name,
          type: type,
          currency: Value(currency),
          openingBalanceMinor: Value(opening),
          openingDate: eat(2025, 12, 1, 0),
          institutionId: Value(institution),
        ),
      );

  Future<int> _category(AppDatabase db, String name, CategoryType type) async {
    final found = await (db.select(
      db.categories,
    )..where((c) => c.name.equals(name))).getSingleOrNull();
    if (found != null) return found.id;
    return db
        .into(db.categories)
        .insert(CategoriesCompanion.insert(name: name, type: type));
  }

  Future<int> _payee(AppDatabase db, String name) =>
      db.into(db.payees).insert(PayeesCompanion.insert(displayName: name));

  Future<int> tx(
    AppDatabase db,
    int account,
    DateTime at,
    int amount,
    TransactionDirection direction,
    TransactionKind kind, {
    int fee = 0,
    int? payee,
    int? category,
    String? receipt,
    String currency = 'KES',
    int? owedAfter,
    String? counterparty,
  }) => db
      .into(db.transactions)
      .insert(
        TransactionsCompanion.insert(
          accountId: account,
          occurredAt: at,
          amountMinor: amount,
          direction: direction,
          kind: Value(kind),
          feeMinor: Value(fee),
          currency: Value(currency),
          payeeId: Value(payee),
          categoryOverrideId: Value(category),
          receiptNo: Value(receipt),
          owedAfterMinor: Value(owedAfter),
          counterpartyName: Value(counterparty),
          source: TransactionSource.manual,
        ),
      );

  Future<void> _pair(AppDatabase db, int out, int into) async {
    await (db.update(db.transactions)..where((t) => t.id.equals(out))).write(
      TransactionsCompanion(transferPairId: Value(into)),
    );
    await (db.update(db.transactions)..where((t) => t.id.equals(into))).write(
      TransactionsCompanion(transferPairId: Value(out)),
    );
  }

  /// Accounts, payees and the month's first half: some written before the
  /// spaces are sent, so the check by hash must find them.
  Future<void> firstHalf() async {
    final p = personalDb;
    mpesa = await _account(
      p,
      'M-Pesa',
      AccountType.mpesa,
      opening: 400000,
      institution: 'mpesa',
    );
    kcb = await _account(p, 'KCB', AccountType.bank, opening: 2000000);
    cash = await _account(p, 'Cash', AccountType.cash, opening: 50000);
    dollars = await _account(
      p,
      'Dollar account',
      AccountType.bank,
      currency: 'USD',
      opening: 10000,
    );
    naivas = await _payee(p, 'Naivas Made-up');
    employer = await _payee(p, 'Example Employer Ltd');
    food = await _category(p, 'Food', CategoryType.expense);
    salary = await _category(p, 'Salary', CategoryType.income);
    final transfer = await _category(p, 'Own transfer', CategoryType.transfer);

    // Before Send from: in the opening balances, never sent.
    await tx(
      p,
      mpesa,
      eat(2025, 12, 20),
      100000,
      TransactionDirection.outflow,
      TransactionKind.till,
      payee: naivas,
      category: food,
      receipt: 'TLA0000001',
    );

    await tx(
      p,
      kcb,
      eat(2026, 11, 1),
      5000000,
      TransactionDirection.inflow,
      TransactionKind.bank,
      payee: employer,
      category: salary,
      receipt: 'FT00000001',
    );
    // An own transfer, KCB to M-Pesa, with a bank fee on the way out.
    final out = await tx(
      p,
      kcb,
      eat(2026, 11, 2),
      1000000,
      TransactionDirection.outflow,
      TransactionKind.bank,
      fee: 5000,
      category: transfer,
      receipt: 'FT00000002',
    );
    final into = await tx(
      p,
      mpesa,
      eat(2026, 11, 2, 9, 1),
      1000000,
      TransactionDirection.inflow,
      TransactionKind.received,
      category: transfer,
      receipt: 'TLB0000002',
    );
    await _pair(p, out, into);
    groceries = await tx(
      p,
      mpesa,
      eat(2026, 11, 3),
      230000,
      TransactionDirection.outflow,
      TransactionKind.till,
      payee: naivas,
      category: food,
      receipt: 'TLC0000003',
    );
  }

  /// Turns sending on for both spaces.
  Future<void> startSending() async {
    await FireflySpaceStore(personalDb).setSending(true);
    await FireflySpaceStore(businessDb).setSending(true);
  }

  /// The rest of the month, written while the spaces are sent.
  Future<void> secondHalf() async {
    final p = personalDb;
    final lunchPlace = await _payee(p, 'Mama Lunch Made-up');
    lunch = await tx(
      p,
      mpesa,
      eat(2026, 11, 4, 13),
      50000,
      TransactionDirection.outflow,
      TransactionKind.sent,
      fee: 700,
      payee: lunchPlace,
      category: food,
      receipt: 'TLD0000004',
    );
    // A Fuliza draw with its access fee, then its repayment.
    await tx(
      p,
      mpesa,
      eat(2026, 11, 5, 18),
      80000,
      TransactionDirection.inflow,
      TransactionKind.fulizaDraw,
      fee: 800,
      owedAfter: 80800,
      receipt: 'TLE0000005',
    );
    await tx(
      p,
      mpesa,
      eat(2026, 11, 5, 18, 1),
      300000,
      TransactionDirection.outflow,
      TransactionKind.paybill,
      payee: naivas,
      category: food,
      receipt: 'TLF0000006',
    );
    await tx(
      p,
      mpesa,
      eat(2026, 11, 9),
      80800,
      TransactionDirection.outflow,
      TransactionKind.fulizaRepayment,
      receipt: 'TLG0000007',
    );
    // A bank charge on its own.
    await tx(
      p,
      kcb,
      eat(2026, 11, 10),
      3000,
      TransactionDirection.outflow,
      TransactionKind.charge,
      receipt: 'CHG0000008',
    );
    // Money in from someone not named yet.
    await tx(
      p,
      mpesa,
      eat(2026, 11, 11),
      70000,
      TransactionDirection.inflow,
      TransactionKind.received,
      counterparty: 'MADE UP SENDER',
      receipt: 'TLH0000009',
    );
    // Cash out at an agent: M-Pesa to Cash.
    final transfer = await _category(p, 'Own transfer', CategoryType.transfer);
    final out = await tx(
      p,
      mpesa,
      eat(2026, 11, 12),
      100000,
      TransactionDirection.outflow,
      TransactionKind.withdrawal,
      fee: 2900,
      category: transfer,
      receipt: 'TLI0000010',
    );
    final into = await tx(
      p,
      cash,
      eat(2026, 11, 12, 9, 5),
      100000,
      TransactionDirection.inflow,
      TransactionKind.deposit,
      category: transfer,
    );
    await _pair(p, out, into);
    // Shillings to dollars: KES 13,050 out of KCB, USD 100.00 in.
    final fxOut = await tx(
      p,
      kcb,
      eat(2026, 11, 13),
      1305000,
      TransactionDirection.outflow,
      TransactionKind.bank,
      category: transfer,
      receipt: 'FT00000011',
    );
    final fxIn = await tx(
      p,
      dollars,
      eat(2026, 11, 13, 9, 30),
      10000,
      TransactionDirection.inflow,
      TransactionKind.bank,
      currency: 'USD',
      category: transfer,
      receipt: 'FT00000012',
    );
    await _pair(p, fxOut, fxIn);
    // A sale on the shared line, moved to the business below.
    sale = await tx(
      p,
      mpesa,
      eat(2026, 11, 14, 11),
      65000,
      TransactionDirection.inflow,
      TransactionKind.received,
      counterparty: 'MADE UP CUSTOMER',
      receipt: 'TLJ0000013',
    );
    // The business's own M-Pesa and a cost.
    final b = businessDb;
    shopMpesa = await _account(b, 'M-Pesa', AccountType.mpesa, opening: 150000);
    final stock = await _category(b, 'Stock', CategoryType.expense);
    final supplier = await _payee(b, 'Wholesale Made-up');
    await tx(
      b,
      shopMpesa,
      eat(2026, 11, 15),
      40000,
      TransactionDirection.outflow,
      TransactionKind.paybill,
      fee: 1500,
      payee: supplier,
      category: stock,
      receipt: 'TLK0000014',
    );
  }

  /// After a first send: an edit, a delete and a move between spaces.
  Future<void> changes() async {
    final p = personalDb;
    await (p.update(p.transactions)..where((t) => t.id.equals(groceries)))
        .write(const TransactionsCompanion(amountMinor: Value(235000)));
    await (p.delete(p.transactions)..where((t) => t.id.equals(lunch))).go();
    await DriftSpaceMoveRepository(
      p,
      (_) async => (businessDb, false),
    ).move(sale, business.id);
  }
}
