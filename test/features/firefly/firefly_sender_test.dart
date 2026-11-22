import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/network/pinned_http_client.dart';
import 'package:pesaclarity/src/core/network/trusted_roots.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/repositories/balances_repair.dart';
import 'package:pesaclarity/src/data/repositories/category_seeds.dart';
import 'package:pesaclarity/src/data/repositories/restore_check.dart';
import 'package:pesaclarity/src/data/repositories/savings_repository.dart';
import 'package:pesaclarity/src/data/repositories/space_move_repository.dart';
import 'package:pesaclarity/src/domain/firefly/firefly_mapping.dart';
import 'package:pesaclarity/src/domain/firefly/firefly_server.dart';
import 'package:pesaclarity/src/domain/savings/savings_product.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/domain/spaces/space_categories.dart';
import 'package:pesaclarity/src/features/firefly/application/firefly_sender.dart';
import 'package:pesaclarity/src/features/firefly/data/firefly_client.dart';
import 'package:pesaclarity/src/features/firefly/data/firefly_space_store.dart';

import 'fake_firefly.dart';
import 'firefly_month.dart';

void main() {
  late FakeFirefly server;
  late FireflyMonth month;

  setUp(() async {
    server = await FakeFirefly.start();
    month = await FireflyMonth.create();
    await month.firstHalf();
  });

  tearDown(() async {
    await month.close();
    await server.close();
  });

  FireflyClient client({String? token, Duration? timeout}) {
    final address = parseFireflyAddress(server.url).address!;
    final factory = HttpClientFactory(TrustedRoots.of(const [], const []));
    return FireflyClient(
      server: address,
      token: token ?? server.token,
      connect: (onUntrusted) =>
          factory.createForUserServer(address.base, onUntrusted: onUntrusted),
      timeout: timeout ?? const Duration(seconds: 5),
    );
  }

  FireflySender sender([FireflyClient? c]) {
    final firefly = c ?? client();
    addTearDown(firefly.close);
    return FireflySender(
      client: firefly,
      from: fireflyFrom,
      offset: const Duration(hours: 3),
      pause: Duration.zero,
    );
  }

  FireflySpaceStore store() => FireflySpaceStore(month.personalDb);

  Future<List<FireflyOutboxRow>> outbox() =>
      month.personalDb.select(month.personalDb.fireflyOutbox).get();

  group('the outbox', () {
    test('stays empty while the space is not sent', () async {
      expect(await outbox(), isEmpty);
    });

    test('is written with the change, and the latest change wins', () async {
      await store().setSending(true);
      final id = await month.tx(
        month.personalDb,
        month.mpesa,
        eat(2026, 11, 20),
        1000,
        TransactionDirection.outflow,
        TransactionKind.till,
      );
      expect((await outbox()).single.action, 'send');
      final p = month.personalDb;
      await (p.update(p.transactions)..where((t) => t.id.equals(id))).write(
        const TransactionsCompanion(amountMinor: Value(1200)),
      );
      final rows = await outbox();
      expect(rows, hasLength(1));
      expect(rows.single.transactionId, id);
    });

    test(
      'a transaction made and deleted before sending sends nothing',
      () async {
        await store().setSending(true);
        final p = month.personalDb;
        final id = await month.tx(
          p,
          month.mpesa,
          eat(2026, 11, 20),
          1000,
          TransactionDirection.outflow,
          TransactionKind.till,
        );
        await (p.delete(p.transactions)..where((t) => t.id.equals(id))).go();
        expect(await outbox(), isEmpty);
        final report = await sender().sendSpace(month.personal, p);
        expect(
          server.live.where((s) => s['external_id'] == 'pesaclarity:homex:$id'),
          isEmpty,
        );
        expect(report.waiting, 0);
      },
    );

    test(
      'nothing is lost if the app stops between the change and sending',
      () async {
        final dir = await Directory.systemTemp.createTemp('firefly');
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/space.sqlite');
        var db = AppDatabase(NativeDatabase(file));
        final account = await db
            .into(db.accounts)
            .insert(
              AccountsCompanion.insert(
                name: 'Cash',
                type: AccountType.cash,
                openingDate: DateTime.utc(2026),
              ),
            );
        await FireflySpaceStore(db).setSending(true);
        await month.tx(
          db,
          account,
          eat(2026, 11, 20),
          500,
          TransactionDirection.outflow,
          TransactionKind.bank,
        );
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        addTearDown(db.close);
        expect(await FireflySpaceStore(db).waitingCount(), 1);
      },
    );

    test(
      'turning a space off drops what waits and keeps what was sent',
      () async {
        await month.startSending();
        await month.secondHalf();
        await sender().sendSpace(month.personal, month.personalDb);
        final sent = await store().allSent();
        expect(sent, isNotEmpty);
        await month.tx(
          month.personalDb,
          month.mpesa,
          eat(2026, 11, 20),
          1000,
          TransactionDirection.outflow,
          TransactionKind.till,
        );
        expect(await store().waitingCount(), 1);
        await store().setSending(false);
        expect(await store().waitingCount(), 0);
        expect(await store().allSent(), hasLength(sent.length));
        // Off, changes are not queued.
        await month.tx(
          month.personalDb,
          month.mpesa,
          eat(2026, 11, 21),
          1000,
          TransactionDirection.outflow,
          TransactionKind.till,
        );
        expect(await store().waitingCount(), 0);
      },
    );
  });

  group('sending', () {
    setUp(() async {
      await month.startSending();
      await month.secondHalf();
    });

    test('sends everything once, each with its external id', () async {
      final report = await sender().sendSpace(month.personal, month.personalDb);
      expect(report.refused, 0);
      expect(report.waiting, 0);
      final externals = [for (final s in server.live) s['external_id']];
      expect(externals.toSet(), hasLength(externals.length));
      expect(
        externals,
        everyElement(startsWith('pesaclarity:${month.personal.id}:')),
      );
      // Sending again sends nothing.
      final count = server.requests
          .where((r) => r == 'POST /api/v1/transactions')
          .length;
      final again = await sender().sendSpace(month.personal, month.personalDb);
      expect(again.sent + again.deleted, 0);
      expect(
        server.requests.where((r) => r == 'POST /api/v1/transactions'),
        hasLength(count),
      );
    });

    test('a lost record is rebuilt by external id: nothing twice', () async {
      await sender().sendSpace(month.personal, month.personalDb);
      final made = server.live.length;
      // As after a restore from a copy taken before the first send.
      final p = month.personalDb;
      await p.delete(p.fireflySent).go();
      await p.delete(p.fireflyAccounts).go();
      await sender().sendSpace(month.personal, month.personalDb);
      expect(server.live, hasLength(made));
      expect(await store().allSent(), isNotEmpty);
    });

    test('a duplicate answer adopts what Firefly III has', () async {
      await sender().sendSpace(month.personal, month.personalDb);
      final p = month.personalDb;
      final row = (await store().allSent()).values.first;
      // Its record lost, but the outbox row already tried once.
      await store().forgetSent(row.transactionId);
      await p
          .update(p.fireflySent)
          .write(const FireflySentCompanion(hash: Value('stale')));
      await store().queue(row.transactionId);
      final made = server.live.length;
      await sender().sendSpace(month.personal, month.personalDb);
      expect(server.live, hasLength(made));
      final again = await store().sent(row.transactionId);
      expect(sentGroups(again!).values.first.id, isNotEmpty);
    });

    test('an edit sends only what changed', () async {
      await sender().sendSpace(month.personal, month.personalDb);
      final p = month.personalDb;
      await (p.update(p.transactions)
            ..where((t) => t.id.equals(month.groceries)))
          .write(const TransactionsCompanion(amountMinor: Value(235000)));
      await sender().sendSpace(month.personal, month.personalDb);
      final puts = server.bodies.entries
          .where((e) => e.key.startsWith('PUT /api/v1/transactions/'))
          .expand((e) => e.value)
          .toList();
      final edit = puts.firstWhere(
        (b) =>
            ((b['transactions']! as List).single as Map)['amount'] == '2350.00',
      );
      final split = (edit['transactions']! as List).single as Map;
      expect(split.keys, ['amount']);
      expect(edit['apply_rules'], isFalse);
    });

    test(
      'deleted in Firefly III: not sent again until Send everything again',
      () async {
        await sender().sendSpace(month.personal, month.personalDb);
        final sent = await store().sent(month.groceries);
        final group = sentGroups(sent!)['']!.id;
        server.deleted.add(group);
        final p = month.personalDb;
        await (p.update(p.transactions)
              ..where((t) => t.id.equals(month.groceries)))
            .write(const TransactionsCompanion(amountMinor: Value(240000)));
        await sender().sendSpace(month.personal, month.personalDb);
        expect((await store().sent(month.groceries))!.removedThere, isTrue);
        await sender().sendSpace(month.personal, month.personalDb);
        expect(
          server.live.where(
            (s) =>
                s['external_id'] ==
                'pesaclarity:${month.personal.id}:${month.groceries}',
          ),
          isEmpty,
        );
        await sender().sendSpace(
          month.personal,
          month.personalDb,
          resendAll: true,
        );
        expect(
          server.live.where(
            (s) =>
                s['external_id'] ==
                'pesaclarity:${month.personal.id}:${month.groceries}',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'a delete deletes there; a switch to another space is sent from there',
      () async {
        await sender().sendSpace(month.personal, month.personalDb);
        await sender().sendSpace(month.business, month.businessDb);
        final saleExternal = 'pesaclarity:${month.personal.id}:${month.sale}';
        await month.changes();
        await sender().sendSpace(month.personal, month.personalDb);
        await sender().sendSpace(month.business, month.businessDb);
        expect(
          server.live.where(
            (s) =>
                s['external_id'] ==
                'pesaclarity:${month.personal.id}:${month.lunch}',
          ),
          isEmpty,
        );
        // The sale on the shared line is switched (decision 0027): it is on
        // the owner's account in the business now, so Personal's goes and
        // the business sends its own, once. The balance record Personal
        // keeps is no transaction and is not sent.
        expect(
          server.live.where((s) => s['external_id'] == saleExternal),
          isEmpty,
        );
        final switched = await (month.businessDb.select(
          month.businessDb.transactions,
        )..where((t) => t.linkId.isNotNull())).getSingle();
        final there = server.live.where(
          (s) =>
              s['external_id'] ==
              'pesaclarity:${month.business.id}:${switched.id}',
        );
        expect(there, hasLength(1));
        expect(there.single['tags'], contains(month.business.name));
      },
    );

    test('the M-Pesa family (decision 0026): M-Shwari, Ziidi and Pochi are '
        'asset accounts there, each at its balance here', () async {
      final p = month.personalDb;
      await sender().sendSpace(month.personal, p);
      // Money into Ziidi and back, read by older readers as plain sends.
      await month.tx(
        p,
        month.mpesa,
        eat(2026, 11, 5, 10),
        300000,
        TransactionDirection.outflow,
        TransactionKind.sent,
        receipt: 'TMZ0000001',
        counterparty: 'ZIIDI',
      );
      await month.tx(
        p,
        month.mpesa,
        eat(2026, 11, 12, 10),
        100000,
        TransactionDirection.inflow,
        TransactionKind.received,
        receipt: 'TMZ0000002',
        counterparty: 'ZIIDI',
      );
      // Into M-Shwari, whose balance the message printed.
      final shwari = await month.tx(
        p,
        month.mpesa,
        eat(2026, 11, 6, 10),
        50000,
        TransactionDirection.outflow,
        TransactionKind.paybill,
        receipt: 'TMZ0000003',
        counterparty: 'M-Shwari',
      );
      await (p.update(p.transactions)..where((t) => t.id.equals(shwari))).write(
        const TransactionsCompanion(otherBalanceMinor: Value(150000)),
      );
      // A sale into the person's own Pochi, with the balance it printed.
      final pochi = await p
          .into(p.accounts)
          .insert(
            AccountsCompanion.insert(
              name: 'Pochi la Biashara',
              type: AccountType.other,
              openingDate: eat(2026, 11, 1),
              institutionId: const Value('mpesa'),
              reference: const Value('pochi'),
              familyOf: Value(month.mpesa),
            ),
          );
      final sale = await month.tx(
        p,
        pochi,
        eat(2026, 11, 7, 10),
        120000,
        TransactionDirection.inflow,
        TransactionKind.received,
        receipt: 'TMZ0000004',
        counterparty: 'MADE-UP CUSTOMER',
      );
      await (p.update(p.transactions)..where((t) => t.id.equals(sale))).write(
        const TransactionsCompanion(balanceAfterMinor: Value(620000)),
      );
      await repairBalancesOnce(p);
      // The person said Add to each (decision 0026 item 5).
      final savings = DriftSavingsRepository(p);
      for (final product in [ziidi, mshwari]) {
        await savings.add(product, at: eat(2026, 11, 20));
      }
      await savings.dispose();
      await sender().sendSpace(month.personal, p);
      expect([
        for (final d in await sender().checkBalances(month.personal, p))
          '${d.name}: ${d.thereMinor} there, ${d.expectedMinor} here',
      ], isEmpty);
      final types = {
        for (final a in server.accounts.values) a['name']: a['type'],
      };
      expect(types['Ziidi · ${month.personal.name}'], 'asset');
      expect(types['M-Shwari · ${month.personal.name}'], 'asset');
      expect(types['Pochi la Biashara · ${month.personal.name}'], 'asset');
      // Moved, never spent or earned: no expense or revenue for them.
      expect([
        for (final MapEntry(:key, :value) in types.entries)
          if ((value == 'expense' || value == 'revenue') &&
              RegExp('ziidi|shwari', caseSensitive: false).hasMatch('$key'))
            key,
      ], isEmpty);
    });

    test('after a switch, every account there ends at its balance here, '
        'in both spaces', () async {
      Future<void> sendBoth() async {
        await sender().sendSpace(month.personal, month.personalDb);
        await sender().sendSpace(month.business, month.businessDb);
      }

      Future<void> expectNoDifference() async {
        for (final (space, db) in [
          (month.personal, month.personalDb),
          (month.business, month.businessDb),
        ]) {
          expect(
            [
              for (final d in await sender().checkBalances(space, db))
                '${d.name}: ${d.thereMinor} there, ${d.expectedMinor} here',
            ],
            isEmpty,
            reason: space.name,
          );
        }
      }

      await sendBoth();
      await expectNoDifference();
      // The sale on the shared line is switched to the business (decision
      // 0027): Personal keeps it on M-Pesa, held for the business, and the
      // business has it on the owner's account.
      await month.changes();
      await sendBoth();
      await expectNoDifference();
      final accounts = {
        for (final a in server.accounts.values) a['name']: a['type'],
      };
      expect(
        accounts.entries
            .where((e) => '${e.key}'.startsWith('Held for'))
            .map((e) => e.value),
        ['liabilities'],
      );
    });

    group('money between spaces, the rest of decision 0027', () {
      Future<void> sendBoth() async {
        await sender().sendSpace(month.personal, month.personalDb);
        await sender().sendSpace(month.business, month.businessDb);
      }

      Future<void> expectNoDifference() async {
        for (final (space, db) in [
          (month.personal, month.personalDb),
          (month.business, month.businessDb),
        ]) {
          expect(
            [
              for (final d in await sender().checkBalances(space, db))
                '${d.name}: ${d.thereMinor} there, ${d.expectedMinor} here',
            ],
            isEmpty,
            reason: space.name,
          );
        }
      }

      /// Put money in, as the sheet writes it: KES 3,000 staying on the
      /// owner's M-Pesa, and KES 1,000 from Personal's cash into the
      /// business's own M-Pesa.
      Future<void> putMoneyIn() async {
        final p = month.personalDb;
        final b = month.businessDb;
        final line = await (p.select(
          p.accounts,
        )..where((a) => a.id.equals(month.mpesa))).getSingle();
        final at = DateTime.utc(2026, 11, 21, 7, 12);
        const link = 'putin:test:1';
        final held = await ensureHeldForAccount(
          p,
          spaceId: month.business.id,
          account: line,
          spaceName: month.business.name,
        );
        final intoBusiness = await ensureCategory(p, putIntoBusinessSeed);
        await p
            .into(p.transactions)
            .insert(
              TransactionsCompanion.insert(
                accountId: held,
                occurredAt: at,
                amountMinor: 300000,
                direction: TransactionDirection.outflow,
                source: TransactionSource.manual,
                counterpartyName: Value(month.business.name),
                categoryOverrideId: Value(intoBusiness),
                linkId: const Value(link),
                linkedSpaceId: Value(month.business.id),
              ),
            );
        final owners = await ensureOwnersAccount(
          b,
          spaceId: personalSpaceId,
          account: line,
          spaceName: 'Personal',
        );
        final capital = await ensureCategory(b, ownerCapitalSeed);
        await b
            .into(b.transactions)
            .insert(
              TransactionsCompanion.insert(
                accountId: owners,
                occurredAt: at,
                amountMinor: 300000,
                direction: TransactionDirection.inflow,
                source: TransactionSource.manual,
                categoryOverrideId: Value(capital),
                linkId: const Value(link),
                linkedSpaceId: const Value(personalSpaceId),
              ),
            );
        await month.tx(
          p,
          month.cash,
          at,
          100000,
          TransactionDirection.outflow,
          TransactionKind.withdrawal,
          category: intoBusiness,
          counterparty: month.business.name,
        );
        await month.tx(
          b,
          month.shopMpesa,
          at,
          100000,
          TransactionDirection.inflow,
          TransactionKind.deposit,
          category: capital,
        );
      }

      test('Put money in: each side sent once, every account at its balance '
          'here, never a sale', () async {
        await sendBoth();
        await month.changes();
        await putMoneyIn();
        await sendBoth();
        await expectNoDifference();
        final capital = server.live.where(
          (s) => s['description'] == fireflyPutInByYou,
        );
        expect(capital, hasLength(2), reason: 'the business side of each');
        expect(capital.map((s) => s['type']), everyElement('deposit'));
      });

      test('the restore remakes: made again in the business, or they were '
          "Personal's own, every account at its balance here", () async {
        await sendBoth();
        await month.changes();
        await putMoneyIn();
        await sendBoth();
        // The business restored from before the switch and the Put money
        // in: its sides are gone.
        final b = month.businessDb;
        final p = month.personalDb;
        await (b.delete(
          b.transactions,
        )..where((t) => t.linkId.isNotNull())).go();
        final missing = await missingInBusiness(
          personal: p,
          business: b,
          businessId: month.business.id,
        );
        expect(missing, hasLength(2));
        await remakeInBusiness(personal: p, business: b, payments: missing);
        await sendBoth();
        await expectNoDifference();

        // Again, and this time they were the owner's own.
        await (b.delete(
          b.transactions,
        )..where((t) => t.linkId.isNotNull())).go();
        await wereMine(
          personal: p,
          businessId: month.business.id,
          payments: await missingInBusiness(
            personal: p,
            business: b,
            businessId: month.business.id,
          ),
        );
        await sendBoth();
        await expectNoDifference();
      });

      test('Personal restored: its side made again in full, every account '
          'at its balance here', () async {
        await sendBoth();
        await month.changes();
        await putMoneyIn();
        await sendBoth();
        final b = month.businessDb;
        final p = month.personalDb;
        await p.delete(p.balanceRecords).go();
        await (p.delete(
          p.transactions,
        )..where((t) => t.linkId.isNotNull())).go();
        final missing = await missingInPersonal(personal: p, business: b);
        expect(missing, hasLength(2));
        await remakeInPersonal(
          personal: p,
          businessId: month.business.id,
          businessName: month.business.name,
          payments: missing,
        );
        await sendBoth();
        await expectNoDifference();
      });
    });

    test('a move outright keeps the record and retags', () async {
      final p = month.personalDb;
      final bus = await month.tx(
        p,
        month.cash,
        DateTime.utc(2026, 11, 16, 8),
        20000,
        TransactionDirection.outflow,
        TransactionKind.bank,
        counterparty: 'MADE UP BUS',
      );
      await sender().sendSpace(month.personal, p);
      await sender().sendSpace(month.business, month.businessDb);
      final external = 'pesaclarity:${month.personal.id}:$bus';
      expect(
        server.live.where((s) => s['external_id'] == external),
        isNotEmpty,
      );
      final made = server.live.length;
      // Typed by hand on an account no messages are read into: it moves
      // whole, and Firefly III keeps the one transaction, retagged.
      await DriftSpaceMoveRepository(
        p,
        (_) async => (month.businessDb, false),
      ).move(bus, month.business.id);
      await sender().sendSpace(month.personal, p);
      await sender().sendSpace(month.business, month.businessDb);
      final moved = server.live.singleWhere(
        (s) => s['external_id'] == external,
      );
      expect(moved['tags'], contains(month.business.name));
      expect(server.live.length, made);
      final kept = await FireflySpaceStore(month.businessDb).allSent();
      expect(kept.values.map((r) => r.externalId), contains(external));
    });

    test('a move to a space not sent deletes it there', () async {
      await sender().sendSpace(month.personal, month.personalDb);
      await FireflySpaceStore(month.businessDb).setSending(false);
      await month.changes();
      await sender().sendSpace(month.personal, month.personalDb);
      expect(
        server.live.where(
          (s) =>
              s['external_id'] ==
              'pesaclarity:${month.personal.id}:${month.sale}',
        ),
        isEmpty,
      );
    });
  });

  group('problems', () {
    setUp(() async {
      await month.startSending();
      await month.secondHalf();
    });

    test('a refused token stops the run, and nothing is lost', () async {
      await expectLater(
        sender(client(token: 'wrong'))
            .sendSpace(month.personal, month.personalDb),
        throwsA(isA<FireflyTokenRefused>()),
      );
      expect(await store().waitingCount(), greaterThan(0));
    });

    test('out of reach stops the run', () async {
      await server.close();
      await expectLater(
        sender().sendSpace(month.personal, month.personalDb),
        throwsA(isA<FireflyUnreachable>()),
      );
      expect(await store().waitingCount(), greaterThan(0));
    });

    test('a timeout is out of reach', () async {
      server.delay = const Duration(seconds: 2);
      await expectLater(
        client(timeout: const Duration(milliseconds: 300)).about(),
        throwsA(isA<FireflyUnreachable>()),
      );
    });

    test('a server error backs off; the rest carry on', () async {
      server.failOn['POST /api/v1/transactions'] = 503;
      final report = await sender().sendSpace(month.personal, month.personalDb);
      expect(report.sent, 0);
      final rows = await outbox();
      expect(rows, isNotEmpty);
      expect(rows.every((r) => r.nextTryAt != null && r.attempts == 1), isTrue);
      expect(rows.first.lastError, contains('503'));
      // Not due yet: the next run waits.
      server.failOn.clear();
      final soon = await sender().sendSpace(month.personal, month.personalDb);
      expect(soon.sent, 0);
    });

    test('a redirect is refused and never followed', () async {
      server.failWith = 302;
      await expectLater(client().about(), throwsA(isA<FireflyRedirected>()));
      expect(server.requests, hasLength(1));
    });

    test(
      'a refused transaction is kept with its reason, the rest go',
      () async {
        server.refuse.add(
          'pesaclarity:${month.personal.id}:${month.groceries}',
        );
        final report = await sender().sendSpace(
          month.personal,
          month.personalDb,
        );
        expect(report.refused, 1);
        final refused = await store().refused();
        expect(refused.single.transactionId, month.groceries);
        expect(refused.single.lastError, contains('more than zero'));
        expect(report.sent, greaterThan(5));
        // Skipped until it changes; a change queues it again.
        final p = month.personalDb;
        await (p.update(p.transactions)
              ..where((t) => t.id.equals(month.groceries)))
            .write(const TransactionsCompanion(amountMinor: Value(231000)));
        expect(await store().refused(), isEmpty);
      },
    );
  });
}
