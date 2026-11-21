import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/firefly/firefly_server.dart';

void main() {
  group('server address', () {
    test('https is the usual, and a bare name becomes https', () {
      final a = parseFireflyAddress(' firefly.example.home/ ').address!;
      expect(a.base.toString(), 'https://firefly.example.home');
      expect(a.isPlain, isFalse);
      expect(
        a.resolve('/api/v1/about').toString(),
        'https://firefly.example.home/api/v1/about',
      );
    });

    test('keeps a port and a path under the server', () {
      final a = parseFireflyAddress('https://Example.home:8443/firefly/')
          .address!;
      expect(a.host, 'example.home');
      expect(a.port, 8443);
      expect(
        a.resolve('/api/v1/about', {'q': 'x'}).toString(),
        'https://example.home:8443/firefly/api/v1/about?q=x',
      );
    });

    test('plain http only on the home network', () {
      for (final ok in [
        'http://192.168.1.20:8080',
        'http://10.0.0.5',
        'http://172.16.4.4',
        'http://172.31.255.1',
        'http://firefly.local',
        'http://firefly.home.arpa',
        'http://localhost:8080',
      ]) {
        final parsed = parseFireflyAddress(ok);
        expect(parsed.address?.isPlain, isTrue, reason: ok);
      }
      for (final no in [
        'http://firefly.example.com',
        'http://8.8.8.8',
        'http://172.32.0.1',
        'http://192.169.1.1',
      ]) {
        expect(
          parseFireflyAddress(no).problem,
          FireflyAddressProblem.plainOnInternet,
          reason: no,
        );
      }
    });

    test('refuses what is not a plain server address', () {
      expect(
        parseFireflyAddress('').problem,
        FireflyAddressProblem.notAnAddress,
      );
      expect(
        parseFireflyAddress('ftp://x.home').problem,
        FireflyAddressProblem.notAnAddress,
      );
      expect(
        parseFireflyAddress('https://user:pw@x.home').problem,
        FireflyAddressProblem.extraParts,
      );
      expect(
        parseFireflyAddress('https://x.home/?token=1').problem,
        FireflyAddressProblem.extraParts,
      );
    });
  });

  group('trusted certificate', () {
    const trusted = TrustedCertificate(host: 'firefly.home', sha256: 'AB12');

    test('trusts exactly its fingerprint, on its host only', () {
      expect(trusted.trusts('FIREFLY.home', 'ab12'), isTrue);
      expect(trusted.trusts('firefly.home', 'AB13'), isFalse);
      expect(trusted.trusts('api.pesaclarity.com', 'AB12'), isFalse);
    });

    test('round-trips through its settings', () {
      final back = TrustedCertificate.fromJson(trusted.toJson())!;
      expect(back.host, trusted.host);
      expect(back.sha256, trusted.sha256);
      expect(TrustedCertificate.fromJson({'host': 1}), isNull);
    });

    test('fingerprints read as people compare them', () {
      expect(hexFingerprint([0x3f, 0xa9, 0x0c]), '3FA90C');
      expect(spacedFingerprint('3fa90c'), '3F:A9:0C');
    });
  });

  test('Firefly III 6.0 or later', () {
    expect(isSupportedFireflyVersion('6.7.9'), isTrue);
    expect(isSupportedFireflyVersion('v6.0.0'), isTrue);
    expect(isSupportedFireflyVersion('10.1.0'), isTrue);
    expect(isSupportedFireflyVersion('5.8.2'), isFalse);
    expect(isSupportedFireflyVersion('develop'), isFalse);
  });

  test('last sent reads plainly', () {
    final now = DateTime.utc(2026, 11, 21, 12);
    expect(sentAgoLabel(now, now), 'just now');
    expect(
      sentAgoLabel(now.subtract(const Duration(minutes: 2)), now),
      '2 min ago',
    );
    expect(
      sentAgoLabel(now.subtract(const Duration(hours: 1)), now),
      '1 hour ago',
    );
    expect(
      sentAgoLabel(now.subtract(const Duration(hours: 30)), now),
      'yesterday',
    );
    expect(
      sentAgoLabel(now.subtract(const Duration(days: 3)), now),
      '3 days ago',
    );
  });
}
