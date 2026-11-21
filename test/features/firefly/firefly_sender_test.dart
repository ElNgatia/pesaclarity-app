import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/network/pinned_http_client.dart';
import 'package:pesaclarity/src/core/network/trusted_roots.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/domain/firefly/firefly_server.dart';
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
      'a delete deletes there; a move keeps the record and retags',
      () async {
        await sender().sendSpace(month.personal, month.personalDb);
        await sender().sendSpace(month.business, month.businessDb);
        final saleExternal = 'pesaclarity:${month.personal.id}:${month.sale}';
        final made = server.live.length;
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
        final sale = server.live.singleWhere(
          (s) => s['external_id'] == saleExternal,
        );
        expect(sale['tags'], contains(month.business.name));
        expect(server.live.length, lessThan(made));
        // The business keeps the record under the sale's id there.
        final moved = await FireflySpaceStore(month.businessDb).allSent();
        expect(moved.values.map((r) => r.externalId), contains(saleExternal));
      },
    );

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
