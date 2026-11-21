// On one line used for both, the channel decides first (decision 0027,
// section 4; owner's decisions 14, 15 and 17), and on the business's own
// accounts a payment out nothing has filed is asked about with "This was
// for me" (section 6; approved screens, choice 3). Made-up data only.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/repositories/space_move_repository.dart';
import 'package:pesaclarity/src/domain/spaces/line_routing.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/features/spaces/application/routing_providers.dart';

import '../../helpers/test_app.dart';

const _stall = 'stall';

void main() {
  final now = DateTime.utc(2026, 11, 21, 9);
  late AppDatabase personal;
  late AppDatabase business;
  late RoutingRules rules;
  late SharedLineRouter router;
  late int mpesa;

  Future<int> received(String name, String phone, int amount) => personal
      .into(personal.transactions)
      .insert(
        TransactionsCompanion.insert(
          accountId: mpesa,
          occurredAt: now.subtract(Duration(hours: amount % 24)),
          amountMinor: amount,
          direction: TransactionDirection.inflow,
          kind: const Value(TransactionKind.received),
          source: TransactionSource.sms,
          counterpartyName: Value(name),
          counterpartyKind: const Value(PayeeIdentifierKind.phone),
          counterpartyValue: Value(phone),
          dedupeKey: Value('$phone|$amount'),
        ),
      );

  setUp(() async {
    personal = openTestDatabase();
    business = openTestDatabase();
    await business.becomeSpace(SpaceKind.business);
    mpesa = await personal
        .into(personal.accounts)
        .insert(
          AccountsCompanion.insert(
            name: 'M-Pesa',
            type: AccountType.mpesa,
            openingDate: DateTime.utc(2026, 11),
            institutionId: const Value('mpesa'),
          ),
        );
    // The owner sets M-Pesa to "Used for both" in Business or personal.
    rules = const RoutingRules().withNewShare('mpesa', _stall);
    router = SharedLineRouter(
      personal: personal,
      moveFromPersonal: DriftSpaceMoveRepository(
        personal,
        (_) async => (business, false),
      ),
      rules: () async => rules,
      remember: (key, space) async => rules = rules.withPerson(key, space),
      saveChannels: (line, channels) async =>
          rules = rules.withChannels(line, channels),
      now: () => now,
    );
  });

  test("money sent to the owner's number is personal, not asked", () async {
    await received('JANE DOE', '254700000001', 50000);
    expect(await router.pending(_stall), isEmpty);
    expect(await personal.select(personal.transactions).get(), hasLength(1));
    expect(await business.select(business.transactions).get(), isEmpty);
  });

  test('"Customers also send money to my number" brings the question '
      'back', () async {
    rules = rules.withChannels(
      'mpesa',
      rules.channelsOn('mpesa').copyWith(customersToNumber: true),
    );
    await received('GRACE WAMBUI', '254700000002', 65000);
    final [q] = await router.pending(_stall);
    expect(q.name, 'GRACE WAMBUI');
    expect(q.through.kind, ChannelKind.ownNumber);
  });

  test('"Is till 123456 Vegetable stall\'s?": Yes names it and sends the '
      'payment to the stall; No asks no more about the till', () async {
    final id = await received('A CUSTOMER', '254700000003', 120000);
    final question = SharedLineQuestion(
      transactionId: id,
      institutionId: 'mpesa',
      amountMinor: 120000,
      currency: 'KES',
      isInflow: true,
      at: now,
      through: const ReceivedThrough(ChannelKind.till, number: '123456'),
      asksNumber: true,
    );
    await router.answerNumber(question, businessId: _stall, ours: true);
    expect(
      rules.channelsOn('mpesa').spaceOf(ChannelKind.till, '123456'),
      _stall,
    );
    expect(await business.select(business.transactions).get(), hasLength(1));
    expect(await personal.select(personal.balanceRecords).get(), hasLength(1));

    await router.answerNumber(
      SharedLineQuestion(
        transactionId: id,
        institutionId: 'mpesa',
        amountMinor: 1,
        currency: 'KES',
        isInflow: true,
        at: now,
        through: const ReceivedThrough(ChannelKind.till, number: '765432'),
        asksNumber: true,
      ),
      businessId: _stall,
      ours: false,
    );
    expect(rules.channelsOn('mpesa').notOurs, {'till:765432'});
    expect(
      rules
          .routeOf(
            'mpesa',
            const ReceivedThrough(ChannelKind.till, number: '765432'),
          )
          .asksNumber,
      isFalse,
      reason: 'No falls back to the business-or-personal question',
    );
  });

  group("the business's own accounts", () {
    late OwnAccountAsker asker;
    late int kcb;

    setUp(() async {
      kcb = await business
          .into(business.accounts)
          .insert(
            AccountsCompanion.insert(
              name: 'KCB',
              type: AccountType.bank,
              openingDate: DateTime.utc(2026, 11),
              institutionId: const Value('kcb'),
            ),
          );
      asker = OwnAccountAsker(
        business: business,
        businessId: _stall,
        moves: DriftSpaceMoveRepository(
          business,
          (_) async => (personal, false),
          sourceSpaceId: _stall,
        ),
        rules: () async => rules,
        remember: (key, space) async => rules = rules.withPerson(key, space),
        now: () => now,
      );
    });

    Future<int> paid(String name, {int? category}) => business
        .into(business.transactions)
        .insert(
          TransactionsCompanion.insert(
            accountId: kcb,
            occurredAt: now.subtract(const Duration(hours: 2)),
            amountMinor: 80000,
            direction: TransactionDirection.outflow,
            kind: const Value(TransactionKind.bank),
            source: TransactionSource.sms,
            counterpartyName: Value(name),
            categoryOverrideId: Value(category),
          ),
        );

    test('asks only when it is unclear', () async {
      await paid("MAMA OLIECH'S KITCHEN");
      final stock = await (business.select(
        business.categories,
      )..where((c) => c.key.equals('stock'))).getSingle();
      await paid('EXAMPLE SUPPLIERS', category: stock.id);
      final asked = await asker.pending();
      expect(asked.map((q) => q.name), ["MAMA OLIECH'S KITCHEN"]);
      expect(asked.single.onOwnAccount, isTrue);
    });

    test('"This was for me" with "Always" makes it Paid yourself, and the '
        "person's next payment too", () async {
      await paid("MAMA OLIECH'S KITCHEN");
      final [q] = await asker.pending();
      await asker.answer(q, forBusiness: false, always: true);
      expect(await personal.select(personal.transactions).get(), hasLength(1));

      await paid("MAMA OLIECH'S KITCHEN");
      expect(await asker.pending(), isEmpty);
      expect(await personal.select(personal.transactions).get(), hasLength(2));
    });

    test('"Business cost" keeps it, and it is not asked again', () async {
      await paid("MAMA OLIECH'S KITCHEN");
      final [q] = await asker.pending();
      await asker.answer(q, forBusiness: true, always: false);
      expect(await asker.pending(), isEmpty);
      expect(await personal.select(personal.transactions).get(), isEmpty);
    });
  });
}
