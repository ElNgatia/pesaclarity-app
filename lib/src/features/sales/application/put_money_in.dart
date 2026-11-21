import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money/money.dart';
import '../../../core/time/clock.dart';
import '../../../data/database/app_database.dart';
import '../../../data/database/database_providers.dart';
import '../../../data/repositories/accounts_repository.dart';
import '../../../data/repositories/category_seeds.dart';
import '../../../data/repositories/quick_records_repository.dart';
import '../../../data/repositories/space_move_repository.dart';
import '../../../domain/spaces/money_between_spaces.dart';
import '../../../domain/spaces/space.dart';
import '../../../domain/spaces/space_categories.dart';
import '../../../domain/time/calendar.dart';
import '../../activity/application/activity_providers.dart';
import '../../spaces/application/business_setup_providers.dart';
import '../../spaces/application/spaces_providers.dart';
import 'pay_yourself.dart';
import 'sales_providers.dart';

/// Where the owner's own money comes from, in Personal (decision 0027, Put
/// money in): their M-Pesa, their cash or one of their banks.
enum PutInSource { mpesa, cash, bank }

/// One of Personal's own accounts the owner can put money in from.
class PutInFrom {
  const PutInFrom({
    required this.source,
    required this.label,
    this.accountId,
    this.accountName,
  });

  final PutInSource source;

  /// As the menu reads: "Your M-Pesa", "Your cash", "Equity bank".
  final String label;

  /// The Personal account, null for cash before Personal has a cash
  /// account.
  final int? accountId;

  /// The account's own name: "M-Pesa", "Equity bank".
  final String? accountName;

  @override
  bool operator ==(Object other) =>
      other is PutInFrom &&
      other.source == source &&
      other.accountId == accountId;

  @override
  int get hashCode => Object.hash(source, accountId);
}

/// Where the money goes in the business.
enum PutInto {
  /// No money moves: part of the owner's M-Pesa becomes the business's.
  staysOnMpesa('Stays on your M-Pesa'),
  businessCash('Business cash'),
  businessBank('Business bank');

  const PutInto(this.label);

  final String label;
}

/// What "Into" the business offers for [from]: "Stays on your M-Pesa" only
/// from the owner's M-Pesa; money that moves can land in the business's
/// cash or bank.
List<PutInto> putIntoFor(PutInSource from) => [
  if (from == PutInSource.mpesa) PutInto.staysOnMpesa,
  PutInto.businessCash,
  PutInto.businessBank,
];

/// The bank's short name in a message line: "Equity bank" reads "Equity".
String bankShortName(String name) =>
    name.replaceFirst(RegExp(r'\s+bank$', caseSensitive: false), '').trim();

/// The note under "Into": what happens on each side, as the approved
/// screens word it.
String putInNotice({
  required PutInFrom from,
  required PutInto into,
  required int amountMinor,
  required String business,
  required String? businessBank,
  required String Function(int minor) money,
}) {
  final short = shortSpaceName(business);
  if (into == PutInto.staysOnMpesa) {
    return 'No money moves. ${money(amountMinor)} of your '
        '${from.accountName ?? 'M-Pesa'} becomes the '
        "$short's.";
  }
  final mine = switch (from.source) {
    PutInSource.cash => null,
    PutInSource.mpesa =>
      'the ${from.accountName ?? 'M-Pesa'} message in Personal',
    PutInSource.bank =>
      'the ${bankShortName(from.accountName ?? 'bank')} message in Personal',
  };
  final theirs = into == PutInto.businessBank
      ? 'the ${businessBank ?? 'bank'} message here'
      : null;
  final both = [?mine, ?theirs];
  if (both.isEmpty) return 'Both sides are saved at once.';
  return 'Send it yourself. It will match ${both.join(' and ')} when '
      '${both.length == 2 ? 'they come' : 'it comes'}.';
}

/// Personal's own accounts the owner can put money in from: their M-Pesa,
/// their cash and each of their banks.
final putInSourcesProvider = FutureProvider.autoDispose<List<PutInFrom>>((
  ref,
) async {
  final personal = ref.watch(personalDatabaseProvider);
  final accounts = await personal.select(personal.accounts).get();
  final cash = accounts.where((a) => a.type == AccountType.cash).firstOrNull;
  return [
    // Each of the owner's M-Pesa lines.
    for (final a in accounts)
      if (a.type == AccountType.mpesa)
        PutInFrom(
          source: PutInSource.mpesa,
          label: 'Your ${a.name}',
          accountId: a.id,
          accountName: a.name,
        ),
    PutInFrom(
      source: PutInSource.cash,
      label: 'Your cash',
      accountId: cash?.id,
      accountName: cash?.name,
    ),
    for (final a in accounts)
      if (a.type == AccountType.bank)
        PutInFrom(
          source: PutInSource.bank,
          label: a.name,
          accountId: a.id,
          accountName: a.name,
        ),
  ];
});

/// The business's first bank account's name, for "the KCB message here".
final businessBankNameProvider = Provider.autoDispose<String?>((ref) {
  final accounts = ref.watch(activityAccountsProvider).value ?? const {};
  return accounts.values
      .where((a) => a.type == AccountType.bank)
      .firstOrNull
      ?.name;
});

/// Put money in (decision 0027): the owner puts their own money into the
/// open business. It is the owner's capital, never owed back: in the
/// business it is "Put in by you", never a sale or income; Personal
/// records it as moved into the business, never as spending, so it counts
/// in neither Out nor the Plan.
class PutMoneyInController {
  PutMoneyInController(this._ref);

  final Ref _ref;

  /// Puts [amountMinor] in [from] Personal [into] the business.
  ///
  /// * Staying on the owner's M-Pesa, no money moves: both sides are
  ///   written at once, with one link, as Pay yourself on the line is, the
  ///   other way. Held for the business goes up in Personal; the
  ///   business's money on the owner's account goes up.
  /// * Otherwise each side is its own: cash is saved at once, M-Pesa and
  ///   bank wait for their own message and pair with it.
  ///
  /// Returns false, writing nothing, when there is nothing to put in.
  Future<bool> putMoneyIn({
    required int amountMinor,
    required PutInFrom from,
    required PutInto into,
  }) async {
    if (amountMinor <= 0) return false;
    final now = _ref.read(clockProvider)();
    final space = _ref.read(activeSpaceProvider);
    final db = _ref.read(appDatabaseProvider);
    final personal = _ref.read(personalDatabaseProvider);

    if (into == PutInto.staysOnMpesa) {
      final line = from.accountId == null
          ? null
          : await (personal.select(
              personal.accounts,
            )..where((a) => a.id.equals(from.accountId!))).getSingleOrNull();
      if (line == null || from.source != PutInSource.mpesa) return false;
      final link = 'putin:${space.id}:${now.microsecondsSinceEpoch}';
      await personal.transaction(() async {
        final held = await ensureHeldForAccount(
          personal,
          spaceId: space.id,
          account: line,
          spaceName: space.name,
        );
        await personal
            .into(personal.transactions)
            .insert(
              TransactionsCompanion.insert(
                accountId: held,
                occurredAt: now,
                amountMinor: amountMinor,
                direction: TransactionDirection.outflow,
                currency: Value(line.currency),
                source: TransactionSource.manual,
                counterpartyName: Value(space.name),
                categoryOverrideId: Value(
                  await ensureCategory(personal, putIntoBusinessSeed),
                ),
                linkId: Value(link),
                linkedSpaceId: Value(space.id),
              ),
            );
      });
      final owners = await ensureOwnersAccount(
        db,
        spaceId: personalSpaceId,
        account: line,
        spaceName: 'Personal',
      );
      await db
          .into(db.transactions)
          .insert(
            TransactionsCompanion.insert(
              accountId: owners,
              occurredAt: now,
              amountMinor: amountMinor,
              direction: TransactionDirection.inflow,
              currency: Value(line.currency),
              source: TransactionSource.manual,
              categoryOverrideId: Value(
                await ensureCategory(db, ownerCapitalSeed),
              ),
              linkId: Value(link),
              linkedSpaceId: const Value(personalSpaceId),
            ),
          );
      return true;
    }

    // The business's side: into its cash at once, or its bank when the
    // message comes.
    await _ref
        .read(quickRecordsRepositoryProvider)
        .putIn(
          at: now,
          amountMinor: amountMinor,
          method: into == PutInto.businessCash
              ? SalePaymentMethod.cash
              : SalePaymentMethod.bank,
          categoryId: await ensureCategory(db, ownerCapitalSeed),
          cashAccountId: await _ref
              .read(accountsRepositoryProvider)
              .cashAccount(
                name: cashAccountName,
                openingDate: CalendarDate.local(now).startInstant,
              ),
        );
    await _ref.read(salesControllerProvider).matchWaiting();

    // Personal's side: out of the owner's cash at once, or their M-Pesa or
    // bank when the message comes.
    final category = await ensureCategory(personal, putIntoBusinessSeed);
    if (from.source == PutInSource.cash) {
      final cash =
          from.accountId ??
          await DriftAccountsRepository(personal).cashAccount(
            name: cashAccountName,
            openingDate: CalendarDate.local(now).startInstant,
          );
      await personal
          .into(personal.transactions)
          .insert(
            TransactionsCompanion.insert(
              accountId: cash,
              occurredAt: now,
              amountMinor: amountMinor,
              direction: TransactionDirection.outflow,
              currency: Value(BaseCurrency.code),
              source: TransactionSource.manual,
              counterpartyName: Value(space.name),
              categoryOverrideId: Value(category),
            ),
          );
      return true;
    }
    await _ref
        .read(payYourselfControllerProvider)
        .expect(
          ExpectedPay(
            amountMinor: amountMinor,
            at: now,
            method: from.source == PutInSource.mpesa
                ? SalePaymentMethod.mpesa
                : SalePaymentMethod.bank,
            categoryKey: putIntoBusinessSeed.key,
            business: space.name,
            kind: ExpectedKind.putIn,
            accountId: from.accountId,
          ),
        );
    return true;
  }
}

final putMoneyInControllerProvider = Provider<PutMoneyInController>(
  PutMoneyInController.new,
);
