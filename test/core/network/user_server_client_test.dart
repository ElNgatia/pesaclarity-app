import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/network/pinned_http_client.dart';
import 'package:pesaclarity/src/core/network/trusted_roots.dart';

import 'pinned_http_client_test.dart' show FakeServer, get;
import 'test_certificate.dart';

/// The SHA-256 fingerprint of the test server's certificate.
const _serverSha256 =
    '2D333882740010B0CF24BCE76457CA6CD3C1649018419C7711FCA2AAC2F2332D';

void main() {
  late FakeServer server;

  setUp(() async => server = await FakeServer.start());
  tearDown(() => server.close());

  // Pinning configured for our own hosts, as in a release build: the
  // person's server must be reached without it, and never with our roots.
  final ours = TrustedRoots.parse(
    hosts: 'api.pesaclarity.com',
    roots: [otherRootsDer[0], otherRootsDer[1]].join(','),
  );

  test("trusts the phone's authorities for the person's server", () async {
    final factory = HttpClientFactory(ours, context: clientContext());
    final url = server.url('/api/v1/about');
    final client = factory.createForUserServer(url.replace(path: ''));
    expect(await get(client, url), 200);
  });

  test(
    'refuses a certificate the phone does not know, and reports it',
    () async {
      final factory = HttpClientFactory(ours, context: SecurityContext());
      final url = server.url('/api/v1/about');
      String? seen;
      final client = factory.createForUserServer(
        url.replace(path: ''),
        onUntrusted: (sha) => seen = sha,
      );
      await expectLater(get(client, url), throwsA(isA<HandshakeException>()));
      expect(seen, _serverSha256);
      expect(server.requests, isEmpty);
    },
  );

  test('accepts exactly the certificate the person chose to trust', () async {
    final factory = HttpClientFactory(ours, context: SecurityContext());
    final url = server.url('/api/v1/about');
    final trusted = factory.createForUserServer(
      url.replace(path: ''),
      trustedSha256: _serverSha256.toLowerCase(),
    );
    expect(await get(trusted, url), 200);

    // A changed certificate is refused, never accepted quietly.
    String? seen;
    final changed = factory.createForUserServer(
      url.replace(path: ''),
      trustedSha256: 'AB' * 32,
      onUntrusted: (sha) => seen = sha,
    );
    await expectLater(get(changed, url), throwsA(isA<HandshakeException>()));
    expect(seen, _serverSha256);
  });

  test('reaches no other host, port or scheme', () async {
    final factory = HttpClientFactory(ours, context: clientContext());
    final url = server.url('/api/v1/about');
    final client = factory.createForUserServer(url.replace(path: ''));
    await expectLater(
      get(client, url.replace(host: 'localhost')),
      throwsA(isA<CertificatePinningException>()),
    );
    await expectLater(
      get(
        factory.createForUserServer(url.replace(path: '')),
        url.replace(port: url.port + 1),
      ),
      throwsA(isA<CertificatePinningException>()),
    );
    await expectLater(
      get(
        factory.createForUserServer(url.replace(path: '')),
        url.replace(scheme: 'http'),
      ),
      throwsA(isA<CertificatePinningException>()),
    );
    expect(server.requests, isEmpty);
  });

  test('our own pinned client is unchanged by a trusted certificate', () async {
    final factory = HttpClientFactory(
      TrustedRoots.parse(hosts: '127.0.0.1', roots: otherRootsDer[0]),
      context: SecurityContext(),
    );
    // The user-server client trusts this certificate ...
    final url = server.url('/api/v1/about');
    expect(
      await get(
        factory.createForUserServer(
          url.replace(path: ''),
          trustedSha256: _serverSha256,
        ),
        url,
      ),
      200,
    );
    // ... and the pinned client still refuses it.
    await expectLater(
      get(factory.create(), url),
      throwsA(isA<HandshakeException>()),
    );
  });
}
