import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/firefly/firefly_mapping.dart';
import 'package:pesaclarity/src/features/firefly/data/firefly_space_reader.dart';

import 'firefly_month.dart';

/// Every own account's opening plus what the parts move must end where the
/// journal does: then Firefly III ends where Pesa Clarity does.
Map<String, (int, int)> _mismatches(FireflySpaceSnapshot s) {
  final moved = fireflyDeltas([for (final p in s.parts.values) ...p]);
  final keys = {...s.openings.keys, ...moved.keys, ...s.balances.keys};
  return {
    for (final key in keys)
      if ((s.openings[key] ?? 0) + (moved[key] ?? 0) != (s.balances[key] ?? 0))
        key: ((s.openings[key] ?? 0) + (moved[key] ?? 0), s.balances[key] ?? 0),
  };
}

void main() {
  late FireflyMonth month;

  setUp(() async {
    month = await FireflyMonth.create();
    await month.firstHalf();
    await month.startSending();
    await month.secondHalf();
  });

  tearDown(() => month.close());

  Future<FireflySpaceSnapshot> read({bool business = false}) =>
      readFireflySpace(
        business ? month.businessDb : month.personalDb,
        space: business ? month.business : month.personal,
        from: fireflyFrom,
      );

  test('the parts and openings end at the journal balances', () async {
    final home = await read();
    expect(_mismatches(home), isEmpty);
    expect(_mismatches(await read(business: true)), isEmpty);

    // M-Pesa opens with what it held on 1 January: 4,000 less the 1,000
    // spent in December.
    expect(home.openings['money:${month.mpesa}'], 300000);
    // Nothing before Send from is sent.
    final ids = home.parts.keys.toSet();
    expect(ids, hasLength(greaterThan(5)));
  });

  test('after an edit, a delete and a move it still adds up', () async {
    await month.changes();
    // The sale switched to the business (decision 0027) leaves a balance
    // record on Personal's M-Pesa. It is never sent as a transaction, so
    // it is not sent twice, but Personal's M-Pesa there is short of the
    // journal by it until Held for is sent (a follow-up to decision 0029).
    expect(_mismatches(await read()), {
      'money:${month.mpesa}': (731300, 731300 + 65000),
    });
    final home = await read();
    expect(home.parts.keys.where((id) => id < 0), isEmpty);
    expect(home.parts.containsKey(month.sale), isFalse);
    expect(_mismatches(await read(business: true)), isEmpty);
  });

  test('fees, Fuliza and transfers become the expected parts', () async {
    final home = await read();
    final all = [for (final p in home.parts.values) ...p];
    // The paired own transfer is one transfer, from KCB to M-Pesa, plus its
    // fee as its own withdrawal to Fees.
    final transfer = all.firstWhere(
      (p) =>
          p.type == FireflyPartType.transfer &&
          p.source.key == 'money:${month.kcb}' &&
          p.destination.key == 'money:${month.mpesa}',
    );
    expect(transfer.amountMinor, 1000000);
    expect(
      all.where(
        (p) =>
            p.suffix == 'fee' &&
            p.destination.name == fireflyFees &&
            p.amountMinor == 5000,
      ),
      hasLength(1),
    );
    // Shillings to dollars: one transfer with the dollars as its foreign
    // amount.
    final fx = all.firstWhere((p) => p.foreignCurrency == 'USD');
    expect(fx.amountMinor, 1305000);
    expect(fx.foreignAmountMinor, 10000);
    // The Fuliza draw comes from the Fuliza liability; its fee adds to
    // what is owed.
    final draw = all.firstWhere(
      (p) => p.source.key == 'fuliza:${month.mpesa}' && p.suffix.isEmpty,
    );
    expect(draw.type, FireflyPartType.deposit);
    expect(draw.amountMinor, 80000);
    // Money in from someone not named yet.
    final unnamed = all.firstWhere(
      (p) => p.source.name == notNamedYet && p.amountMinor == 70000,
    );
    expect(unnamed.tags, contains(fireflyToNameTag));
    expect(unnamed.tags, containsAll([fireflyTag, month.personal.name]));
  });
}
