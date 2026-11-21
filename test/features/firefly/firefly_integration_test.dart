// Sends a made-up month to a real Firefly III and checks that every account
// there ends at the balance Pesa Clarity's journal gives (decision 0029,
// section 10). Skipped unless FIREFLY_URL and FIREFLY_TOKEN are set, for
// example against Firefly III in Docker:
//
//   FIREFLY_URL=http://localhost:8080 FIREFLY_TOKEN=... \
//     flutter test test/features/firefly/firefly_integration_test.dart
//
// Each run uses spaces of its own, so runs never meet in one Firefly III.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/network/pinned_http_client.dart';
import 'package:pesaclarity/src/core/network/trusted_roots.dart';
import 'package:pesaclarity/src/domain/firefly/firefly_server.dart';
import 'package:pesaclarity/src/features/firefly/application/firefly_sender.dart';
import 'package:pesaclarity/src/features/firefly/data/firefly_client.dart';
import 'package:pesaclarity/src/features/firefly/data/firefly_space_store.dart';

import 'firefly_month.dart';

void main() {
  final url = Platform.environment['FIREFLY_URL'] ?? '';
  final token = Platform.environment['FIREFLY_TOKEN'] ?? '';
  final skip = url.isEmpty || token.isEmpty
      ? 'Set FIREFLY_URL and FIREFLY_TOKEN to run against a real Firefly III'
      : null;

  test(
    'a month arrives, adds up, and sending again changes nothing',
    () async {
      final address = parseFireflyAddress(url).address!;
      final factory = HttpClientFactory(TrustedRoots.of(const [], const []));
      final client = FireflyClient(
        server: address,
        token: token,
        connect: (onUntrusted) =>
            factory.createForUserServer(address.base, onUntrusted: onUntrusted),
      );
      addTearDown(client.close);
      final about = await client.about();
      // ignore: avoid_print, the version tested goes in the report
      print('Firefly III ${about.version} (API ${about.apiVersion})');

      final tag = 'IT${DateTime.now().millisecondsSinceEpoch}';
      final month = await FireflyMonth.create(tag: tag);
      addTearDown(month.close);
      await month.firstHalf();
      await month.startSending();
      await month.secondHalf();

      final sender = FireflySender(
        client: client,
        from: fireflyFrom,
        offset: const Duration(hours: 3),
        pause: Duration.zero,
      );
      Future<void> sendBoth() async {
        for (final (space, db) in [
          (month.personal, month.personalDb),
          (month.business, month.businessDb),
        ]) {
          final report = await sender.sendSpace(space, db);
          for (final r in await FireflySpaceStore(db).refused()) {
            // ignore: avoid_print, why Firefly III refused it
            print('Refused ${r.transactionId}: ${r.lastError}');
          }
          expect(report.refused, 0, reason: '${space.name} had refusals');
          expect(report.waiting, 0);
        }
      }

      Future<void> expectBalancesMatch() async {
        for (final (space, db) in [
          (month.personal, month.personalDb),
          (month.business, month.businessDb),
        ]) {
          expect(await sender.checkBalances(space, db), isEmpty);
          expect(await FireflySpaceStore(db).accounts(), isNotEmpty);
        }
      }

      await sendBoth();
      await expectBalancesMatch();

      // An edit, a delete and a move between the spaces arrive too.
      await month.changes();
      final store = FireflySpaceStore(month.personalDb);
      expect(await store.waitingCount(), greaterThan(0));
      await sendBoth();
      await expectBalancesMatch();
      // The deleted payment is gone there. The sale on the shared line is
      // switched to the business (decision 0027): Personal's goes, the
      // business sends it on the owner's account, and Personal sends what
      // it holds for the business against Held for it.
      final lunchId = 'pesaclarity:${month.personal.id}:${month.lunch}';
      expect(await client.findByExternalId(lunchId), isNull);
      final saleId = 'pesaclarity:${month.personal.id}:${month.sale}';
      expect(await client.findByExternalId(saleId), isNull);
      final [record] = await month.personalDb
          .select(month.personalDb.balanceRecords)
          .get();
      expect(
        await client.findByExternalId(
          'pesaclarity:${month.personal.id}:${-record.id}',
        ),
        isNotNull,
      );

      // Sending again changes nothing.
      for (final (space, db) in [
        (month.personal, month.personalDb),
        (month.business, month.businessDb),
      ]) {
        final again = await sender.sendSpace(space, db);
        expect(again.sent + again.deleted, 0, reason: space.name);
      }
      await expectBalancesMatch();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
