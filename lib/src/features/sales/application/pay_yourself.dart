import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money/money.dart';
import '../../../core/time/clock.dart';
import '../../../data/database/app_database.dart';
import '../../../data/database/database_providers.dart';
import '../../../data/repositories/accounts_repository.dart';
import '../../../data/repositories/app_settings_repository.dart';
import '../../../data/repositories/category_seeds.dart';
import '../../../data/repositories/quick_records_repository.dart';
import '../../../data/repositories/space_move_repository.dart';
import '../../../data/repositories/transactions_repository.dart';
import '../../../domain/categories/default_categories.dart';
import '../../../domain/sales/sale_matching.dart';
import '../../../domain/spaces/space.dart';
import '../../../domain/spaces/space_categories.dart';
import '../../../domain/time/calendar.dart';
import '../../spaces/application/business_setup_providers.dart';
import '../../spaces/application/spaces_providers.dart';
import 'sales_providers.dart';

/// How Personal files pay from the owner's business.
enum PersonalPayAs {
  salary('Salary from my business'),
  other('Other income');

  const PersonalPayAs(this.label);

  final String label;

  CategorySeed get seed => switch (this) {
    PersonalPayAs.salary => payFromBusinessSeed,
    PersonalPayAs.other => defaultCategories.firstWhere(
      (c) => c.key == 'business_income',
    ),
  };
}

/// Personal setting holding pay from a business still to meet its message.
const expectedPayKey = 'business.payYourself.expected';

/// What Personal is waiting for: pay from a business coming in, or the
/// owner's money going out into a business (decision 0027, Put money in).
enum ExpectedKind { pay, putIn }

/// Pay from a business that Personal is waiting to see come in, or money
/// put into a business that Personal is waiting to see go out.
class ExpectedPay {
  const ExpectedPay({
    required this.amountMinor,
    required this.at,
    required this.method,
    required this.categoryKey,
    required this.business,
    this.kind = ExpectedKind.pay,
    this.accountId,
  });

  final int amountMinor;
  final DateTime at;
  final SalePaymentMethod method;
  final String categoryKey;
  final String business;
  final ExpectedKind kind;

  /// The Personal account its message comes on, when the owner said which
  /// ("Where it lands", or Put money in's From); any account of [method]'s
  /// kind otherwise.
  final int? accountId;

  Map<String, Object?> toJson() => {
    'amountMinor': amountMinor,
    'atMs': at.millisecondsSinceEpoch,
    'method': method.name,
    'categoryKey': categoryKey,
    'business': business,
    if (kind != ExpectedKind.pay) 'kind': kind.name,
    'accountId': ?accountId,
  };

  static ExpectedPay? fromJson(Object? json) {
    if (json is! Map) return null;
    final amount = json['amountMinor'];
    final at = json['atMs'];
    final method = SalePaymentMethod.values
        .where((m) => m.name == json['method'])
        .firstOrNull;
    final key = json['categoryKey'];
    final business = json['business'];
    final account = json['accountId'];
    if (amount is! int ||
        at is! int ||
        method == null ||
        key is! String ||
        business is! String) {
      return null;
    }
    return ExpectedPay(
      amountMinor: amount,
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      method: method,
      categoryKey: key,
      business: business,
      kind:
          ExpectedKind.values
              .where((k) => k.name == json['kind'])
              .firstOrNull ??
          ExpectedKind.pay,
      accountId: account is int ? account : null,
    );
  }
}

/// Where pay by bank lands in Personal (decision 0027, "Where it lands"):
/// one of the owner's own accounts there, or none Pesa Clarity reads.
sealed class PayLands {
  const PayLands();

  /// The value kept to choose it first next time.
  String get saved;

  static PayLands? parse(String? saved) {
    if (saved == null) return null;
    if (saved == 'untracked') return const LandsUntracked();
    final id = int.tryParse(saved.replaceFirst('account:', ''));
    return id == null ? null : LandsOn(id);
  }
}

/// On Personal's account [accountId]: its message is matched to the pay.
final class LandsOn extends PayLands {
  const LandsOn(this.accountId);

  final int accountId;

  @override
  String get saved => 'account:$accountId';

  @override
  bool operator ==(Object other) =>
      other is LandsOn && other.accountId == accountId;

  @override
  int get hashCode => accountId.hashCode;
}

/// "Not tracked here": Personal counts the pay, and none of its accounts
/// goes up.
final class LandsUntracked extends PayLands {
  const LandsUntracked();

  @override
  String get saved => 'untracked';

  @override
  bool operator ==(Object other) => other is LandsUntracked;

  @override
  int get hashCode => 0;
}

/// Personal setting holding where pay by bank landed last time, chosen
/// first next time.
const payLandsKey = 'business.payYourself.lands';

/// Where pay by bank landed last time, if it is still there to choose.
Future<PayLands?> lastLanding(AppSettingsRepository settings) async {
  final saved = (await settings.readJson(payLandsKey))?['lands'];
  return PayLands.parse(saved is String ? saved : null);
}

Future<List<ExpectedPay>> _expected(AppSettingsRepository settings) async {
  final list = (await settings.readJson(expectedPayKey))?['items'];
  return [
    if (list is List)
      for (final item in list) ?ExpectedPay.fromJson(item),
  ];
}

Future<void> _saveExpected(
  AppSettingsRepository settings,
  List<ExpectedPay> items,
) => settings.writeJson(expectedPayKey, {
  'items': [for (final i in items) i.toJson()],
});

/// Pay yourself: money leaves the business as the owner's pay and comes
/// into Personal as income.
class PayYourselfController {
  PayYourselfController(this._ref);

  final Ref _ref;

  /// The business pays the owner [amountMinor] by [method]; Personal files
  /// it [as] chosen. Cash shows in Personal at once; M-Pesa and bank wait
  /// for their messages on both sides.
  ///
  /// By bank, [lands] says where the money arrives in Personal (decision
  /// 0027): on one of its accounts, whose message is then matched to the
  /// pay and counted once, or "Not tracked here", where Personal counts
  /// the pay at once and none of its accounts goes up. It is kept to be
  /// chosen first next time.
  Future<void> payYourself({
    required int amountMinor,
    required SalePaymentMethod method,
    required PersonalPayAs as,
    PayLands? lands,
  }) async {
    final now = _ref.read(clockProvider)();
    final business = _ref.read(activeSpaceProvider).name;
    final db = _ref.read(appDatabaseProvider);
    await _ref
        .read(quickRecordsRepositoryProvider)
        .paidYourself(
          at: now,
          amountMinor: amountMinor,
          method: method,
          categoryId: await ensureCategory(db, ownerPaySeed),
          cashAccountId: await _ref
              .read(accountsRepositoryProvider)
              .cashAccount(
                name: cashAccountName,
                openingDate: CalendarDate.local(now).startInstant,
              ),
        );
    await _ref.read(salesControllerProvider).matchWaiting();

    final personal = _ref.read(personalDatabaseProvider);
    if (method == SalePaymentMethod.cash) {
      final account = await DriftAccountsRepository(personal).cashAccount(
        name: cashAccountName,
        openingDate: CalendarDate.local(now).startInstant,
      );
      await personal
          .into(personal.transactions)
          .insert(
            TransactionsCompanion.insert(
              accountId: account,
              occurredAt: now,
              amountMinor: amountMinor,
              direction: TransactionDirection.inflow,
              currency: Value(BaseCurrency.code),
              source: TransactionSource.manual,
              counterpartyName: Value(business),
              categoryOverrideId: Value(
                await ensureCategory(personal, as.seed),
              ),
            ),
          );
      return;
    }
    final settings = _ref.read(mainSettingsRepositoryProvider);
    if (lands != null) {
      await settings.writeJson(payLandsKey, {'lands': lands.saved});
    }
    if (lands is LandsUntracked) {
      // Counted once, at once; no account of Personal's goes up: it posts
      // against Paid by the business, like a purchase with its money.
      final space = _ref.read(activeSpaceProvider);
      final paidBy = await ensurePaidByAccount(
        personal,
        spaceId: space.id,
        spaceName: space.name,
      );
      await personal
          .into(personal.transactions)
          .insert(
            TransactionsCompanion.insert(
              accountId: paidBy,
              occurredAt: now,
              amountMinor: amountMinor,
              direction: TransactionDirection.inflow,
              currency: Value(BaseCurrency.code),
              source: TransactionSource.manual,
              counterpartyName: Value(business),
              categoryOverrideId: Value(
                await ensureCategory(personal, as.seed),
              ),
            ),
          );
      return;
    }
    final on = lands is LandsOn
        ? await (personal.select(
            personal.accounts,
          )..where((a) => a.id.equals(lands.accountId))).getSingleOrNull()
        : null;
    await _saveExpected(settings, [
      ...await _expected(settings),
      ExpectedPay(
        amountMinor: amountMinor,
        at: now,
        method: on == null
            ? method
            : on.type == AccountType.mpesa
            ? SalePaymentMethod.mpesa
            : SalePaymentMethod.bank,
        categoryKey: as.seed.key,
        business: business,
        accountId: on?.id,
      ),
    ]);
  }

  /// Adds [item] to what Personal waits for.
  Future<void> expect(ExpectedPay item) async {
    final settings = _ref.read(mainSettingsRepositoryProvider);
    await _saveExpected(settings, [...await _expected(settings), item]);
  }

  /// Pay yourself on a line the business shares with Personal (decision
  /// 0027, section 6): no money moves, so both sides are written at once,
  /// with one link. The business's part of the line, on its owner's account
  /// [ownersAccountId], goes down as Paid yourself; in Personal, Held for
  /// the business goes down and the pay comes in [as] chosen. Never more
  /// than the business has on that line (owner's decision 5): returns false,
  /// writing nothing, when [amountMinor] is more.
  Future<bool> payYourselfOnLine({
    required int amountMinor,
    required int ownersAccountId,
    required PersonalPayAs as,
    required int onLineMinor,
  }) async {
    if (amountMinor <= 0 || amountMinor > onLineMinor) return false;
    final now = _ref.read(clockProvider)();
    final space = _ref.read(activeSpaceProvider);
    final db = _ref.read(appDatabaseProvider);
    final personal = _ref.read(personalDatabaseProvider);
    final owners = await (db.select(
      db.accounts,
    )..where((a) => a.id.equals(ownersAccountId))).getSingle();
    final line = owners.linkedAccountId == null
        ? null
        : await (personal.select(personal.accounts)
                ..where((a) => a.id.equals(owners.linkedAccountId!)))
              .getSingleOrNull();
    if (owners.type != AccountType.ownersAccount ||
        owners.linkedSpaceId != personalSpaceId ||
        line == null) {
      return false;
    }
    final link = 'pay:${space.id}:${now.microsecondsSinceEpoch}';
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
              direction: TransactionDirection.inflow,
              currency: Value(owners.currency),
              source: TransactionSource.manual,
              counterpartyName: Value(space.name),
              categoryOverrideId: Value(
                await ensureCategory(personal, as.seed),
              ),
              linkId: Value(link),
              linkedSpaceId: Value(space.id),
            ),
          );
    });
    await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            accountId: ownersAccountId,
            occurredAt: now,
            amountMinor: amountMinor,
            direction: TransactionDirection.outflow,
            currency: Value(owners.currency),
            source: TransactionSource.manual,
            categoryOverrideId: Value(await ensureCategory(db, ownerPaySeed)),
            linkId: Value(link),
            linkedSpaceId: const Value(personalSpaceId),
          ),
        );
    return true;
  }

  /// In Personal: files pay from a business when its message has come in,
  /// and money put into a business when its message has gone out, and
  /// returns how many were filed.
  Future<int> matchInPersonal() async {
    final settings = _ref.read(mainSettingsRepositoryProvider);
    final expected = await _expected(settings);
    if (expected.isEmpty) return 0;
    final personal = _ref.read(personalDatabaseProvider);
    final seeds = {
      for (final a in PersonalPayAs.values) a.seed.key: a.seed,
      putIntoBusinessSeed.key: putIntoBusinessSeed,
    };
    final waiting = [
      for (final (i, e) in expected.indexed)
        WaitingPayment(
          id: i,
          kind: e.kind == ExpectedKind.putIn
              ? WaitingKind.putIntoBusiness
              : WaitingKind.payFromBusiness,
          method: e.method,
          amountMinor: e.amountMinor,
          currency: BaseCurrency.code,
          at: e.at,
          categoryId: await ensureCategory(
            personal,
            seeds[e.categoryKey] ?? payFromBusinessSeed,
          ),
        ),
    ];
    final from = waiting
        .map((w) => w.at)
        .reduce((a, b) => a.isBefore(b) ? a : b)
        .subtract(saleMatchWindow);
    final to = waiting
        .map((w) => w.at)
        .reduce((a, b) => a.isAfter(b) ? a : b)
        .add(saleMatchWindow);
    final entries = await DriftTransactionsRepository(personal)
        .ledgerEntries(from: from, to: to);
    final accounts = {
      for (final a in await DriftAccountsRepository(personal).openings())
        a.id: a.type,
    };
    // Each in turn, oldest first, on the account the owner named when they
    // named one; each message pays for one only.
    final matches = <WaitingPayment, int>{};
    final used = <int>{};
    for (final w in [...waiting]..sort((a, b) => a.at.compareTo(b.at))) {
      final on = expected[w.id].accountId;
      final found = matchWaitingPayments(
        [w],
        [
          for (final e in entries)
            if (!used.contains(e.id) && (on == null || e.accountId == on)) e,
        ],
        accountTypes: accounts,
        linked: const {},
      );
      if (found[w] case final id?) {
        matches[w] = id;
        used.add(id);
      }
    }
    if (matches.isEmpty) return 0;
    for (final MapEntry(key: w, value: transactionId) in matches.entries) {
      await (personal.update(
        personal.transactions,
      )..where((t) => t.id.equals(transactionId))).write(
        TransactionsCompanion(categoryOverrideId: Value(w.categoryId)),
      );
    }
    final done = {for (final w in matches.keys) w.id};
    await _saveExpected(settings, [
      for (final (i, e) in expected.indexed)
        if (!done.contains(i)) e,
    ]);
    return matches.length;
  }
}

/// One place pay by bank can land in Personal, as "Where it lands" offers
/// it: [label] in the menu, [name] in the note ("the M-Pesa message").
typedef PayLanding = ({PayLands lands, String label, String name});

/// Where pay by bank can land (decision 0027): the owner's M-Pesa, each of
/// their banks in Personal, or "Not tracked here"; and the one used last
/// time, chosen first.
final payLandingsProvider =
    FutureProvider.autoDispose<({List<PayLanding> options, PayLands? last})>((
      ref,
    ) async {
      final personal = ref.watch(personalDatabaseProvider);
      final accounts = await personal.select(personal.accounts).get();
      final options = <PayLanding>[
        for (final a in accounts)
          if (a.type == AccountType.mpesa)
            (lands: LandsOn(a.id), label: 'Your ${a.name}', name: a.name),
        for (final a in accounts)
          if (a.type == AccountType.bank)
            (lands: LandsOn(a.id), label: a.name, name: a.name),
        (lands: const LandsUntracked(), label: 'Not tracked here', name: ''),
      ];
      final last = await lastLanding(ref.watch(mainSettingsRepositoryProvider));
      return (
        options: options,
        last: options.any((o) => o.lands == last) ? last : null,
      );
    });

/// The note under "Where it lands": each side matches its own message, and
/// Personal counts the pay once.
String payLandsNotice({required String? businessBank, required PayLanding to}) {
  final here = 'It will match the ${businessBank ?? 'bank'} message here';
  if (to.lands is LandsUntracked) {
    return '$here. Personal counts the pay, and none of your accounts there '
        'goes up.';
  }
  final name = to.name.replaceFirst(
    RegExp(r'\s+bank$', caseSensitive: false),
    '',
  );
  return '$here and the $name message in Personal. Personal counts it once.';
}

final payYourselfControllerProvider = Provider<PayYourselfController>(
  PayYourselfController.new,
);

/// While Personal is open, files pay from a business as its message comes.
final personalPayMatcherProvider = Provider<void>((ref) {
  if (ref.watch(activeSpaceProvider).kind != SpaceKind.personal) return;
  ref.listen(ledgerChangesProvider, (_, _) async {
    try {
      await ref.read(payYourselfControllerProvider).matchInPersonal();
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Filing pay from a business failed: $error');
    }
  }, fireImmediately: true);
});
