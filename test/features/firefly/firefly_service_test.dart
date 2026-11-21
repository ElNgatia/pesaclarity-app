import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/network/pinned_http_client.dart';
import 'package:pesaclarity/src/core/network/trusted_roots.dart';
import 'package:pesaclarity/src/core/time/clock.dart';
import 'package:pesaclarity/src/data/database/app_database.dart';
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/features/firefly/application/firefly_service.dart';
import 'package:pesaclarity/src/features/firefly/application/firefly_settings.dart';
import 'package:pesaclarity/src/features/firefly/data/firefly_space_store.dart';
import 'package:pesaclarity/src/features/security/data/secure_store.dart';

import '../../helpers/test_app.dart';
import 'fake_firefly.dart';
import 'firefly_month.dart';

void main() {
  late FakeFirefly server;
  late AppDatabase db;
  late MemorySecureStore secure;
  late ProviderContainer container;

  setUp(() async {
    server = await FakeFirefly.start();
    db = openTestDatabase();
    secure = MemorySecureStore();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        personalDatabaseProvider.overrideWithValue(db),
        secureStoreProvider.overrideWithValue(secure),
        httpClientFactoryProvider.overrideWithValue(
          HttpClientFactory(TrustedRoots.of(const [], const [])),
        ),
        clockProvider.overrideWithValue(() => eat(2026, 11, 21, 9, 41)),
      ],
    );
    addTearDown(container.dispose);
    final mpesa = await db
        .into(db.accounts)
        .insert(
          AccountsCompanion.insert(
            name: 'M-Pesa',
            type: AccountType.mpesa,
            openingDate: eat(2026, 1, 1, 0),
          ),
        );
    await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            accountId: mpesa,
            occurredAt: eat(2026, 11, 3),
            amountMinor: 45000,
            direction: TransactionDirection.outflow,
            kind: const Value(TransactionKind.till),
            source: TransactionSource.manual,
          ),
        );
  });

  tearDown(() => server.close());

  FireflyService service() => container.read(fireflyServiceProvider);

  Future<void> connect() async {
    expect(
      await service().check(server.url, token: server.token),
      isA<FireflyNeedsPlainConfirm>(),
    );
    await service().confirmPlain(server.url);
    final result = await service().check(server.url, token: server.token);
    expect(result, isA<FireflyConnected>());
    expect((result as FireflyConnected).version, '6.7.9');
  }

  test('the token is kept on this phone only, never in the database', () async {
    await connect();
    expect(await secure.read(fireflyTokenKey), server.token);
    // Everything the database keeps, which backups copy.
    for (final row in await db.select(db.appSettings).get()) {
      expect(row.value, isNot(contains(server.token)), reason: row.key);
    }
    final settings = await service().settings();
    expect(settings.toJson().toString(), isNot(contains(server.token)));
    expect(settings.address, server.url);
  });

  test('a wrong token fails at Check connection, on the token', () async {
    await service().confirmPlain(server.url);
    final result = await service().check(server.url, token: 'nope');
    expect(result, isA<FireflyCheckFailed>());
    expect((result as FireflyCheckFailed).token, isTrue);
    expect(result.message, isNot(contains('nope')));
    expect(await secure.read(fireflyTokenKey), isNull);
  });

  test(
    'plain http to the internet is refused before anything is sent',
    () async {
      final result = await service().check(
        'http://firefly.example.com',
        token: server.token,
      );
      expect(result, isA<FireflyCheckFailed>());
      expect(server.requests, isEmpty);
    },
  );

  test('starts, sends, and turning off keeps what was sent', () async {
    await connect();
    await service().start({'personal'}, FireflySendFrom.thisYear);
    await service().sendQuietly();
    final settings = await service().settings();
    expect(settings.on, isTrue);
    expect(settings.fromDay.toString(), '2026-01-01');
    expect(settings.lastSentAt, isNotNull);
    expect(settings.problem, isNull);
    expect(server.live, hasLength(1));
    expect((await service().waiting()).waiting, 0);

    await service().turnOff();
    expect(await secure.read(fireflyTokenKey), isNull);
    expect(await FireflySpaceStore(db).sending(), isFalse);
    expect((await service().settings()).on, isFalse);
    // What was sent stays there, and the record of it here.
    expect(server.live, hasLength(1));
    expect(await FireflySpaceStore(db).allSent(), isNotEmpty);
  });

  test('problems are kept for the Firefly III screen, quietly', () async {
    await connect();
    await service().start({'personal'}, FireflySendFrom.thisYear);
    await service().sendQuietly();
    await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            accountId: 1,
            occurredAt: eat(2026, 11, 4),
            amountMinor: 1000,
            direction: TransactionDirection.outflow,
            source: TransactionSource.manual,
          ),
        );

    await server.close();
    await service().sendQuietly();
    expect((await service().settings()).problem, FireflyProblem.unreachable);
    expect((await service().waiting()).waiting, 1);

    server = await FakeFirefly.start();
    server.token = 'a-new-one';
    await service().saveSettings(
      (await service().settings()).copyWith(address: server.url),
    );
    await service().sendQuietly();
    expect((await service().settings()).problem, FireflyProblem.tokenRefused);
    // Sending waits for a new token.
    final calls = server.requests.length;
    await service().sendQuietly();
    expect(server.requests, hasLength(calls));
  });
}
