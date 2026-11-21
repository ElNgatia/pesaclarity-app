/// The person's own Firefly III server (decision 0029): what address they
/// may type, and what Pesa Clarity trusts there. Pure Dart.
library;

/// A server address the person typed, once checked.
class FireflyServerAddress {
  const FireflyServerAddress._(this.base);

  /// The address with no trailing slash, such as
  /// `https://firefly.example.home` or `http://192.168.1.20:8080/firefly`.
  final Uri base;

  String get host => base.host;
  int get port => base.port;

  /// Plain `http`: allowed only on the home network, after a warning.
  bool get isPlain => base.isScheme('http');

  /// [path] under the server, such as `/api/v1/about`.
  Uri resolve(String path, [Map<String, String>? query]) => base.replace(
    path: '${base.path}$path',
    queryParameters: query == null || query.isEmpty ? null : query,
  );

  @override
  String toString() => base.toString();

  @override
  bool operator ==(Object other) =>
      other is FireflyServerAddress && other.base == base;

  @override
  int get hashCode => base.hashCode;
}

/// Why an address cannot be used.
enum FireflyAddressProblem {
  /// Empty, or not an address at all.
  notAnAddress('Type the address of your Firefly III server.'),

  /// Plain `http` to an address on the internet.
  plainOnInternet(
    'Use https. Plain http is only for an address on your home network.',
  ),

  /// A user name, password, query or fragment in the address.
  extraParts('Type only the server address, such as https://firefly.home.');

  const FireflyAddressProblem(this.message);

  /// What the field says under it.
  final String message;
}

/// [text] as a server address, or why it cannot be one. An address with no
/// scheme is taken as `https`. Plain `http` is allowed only for a home
/// network address ([isHomeNetworkHost]); the screen then asks once before
/// it is used.
({FireflyServerAddress? address, FireflyAddressProblem? problem})
parseFireflyAddress(String text) {
  var value = text.trim();
  if (value.isEmpty) {
    return (address: null, problem: FireflyAddressProblem.notAnAddress);
  }
  if (!value.contains('://')) value = 'https://$value';
  final Uri uri;
  try {
    uri = Uri.parse(value);
  } on FormatException {
    return (address: null, problem: FireflyAddressProblem.notAnAddress);
  }
  if (!uri.isScheme('https') && !uri.isScheme('http')) {
    return (address: null, problem: FireflyAddressProblem.notAnAddress);
  }
  if (uri.host.isEmpty || uri.host.contains(' ')) {
    return (address: null, problem: FireflyAddressProblem.notAnAddress);
  }
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
    return (address: null, problem: FireflyAddressProblem.extraParts);
  }
  if (uri.isScheme('http') && !isHomeNetworkHost(uri.host)) {
    return (address: null, problem: FireflyAddressProblem.plainOnInternet);
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return (
    address: FireflyServerAddress._(
      Uri(
        scheme: uri.scheme,
        host: uri.host.toLowerCase(),
        port: uri.hasPort ? uri.port : null,
        path: path,
      ),
    ),
    problem: null,
  );
}

/// Whether [host] is on the home network, where plain `http` may be used
/// after a warning: a private IPv4 address (10.x, 172.16 to 172.31.x,
/// 192.168.x), a `.local` or `.home.arpa` name, or this phone itself.
bool isHomeNetworkHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.local') || h.endsWith('.home.arpa')) {
    return true;
  }
  final parts = h.split('.');
  if (parts.length != 4) return false;
  final octets = [for (final p in parts) int.tryParse(p)];
  if (octets.any((o) => o == null || o < 0 || o > 255)) return false;
  final [a, b, _, _] = [for (final o in octets) o!];
  return a == 10 ||
      a == 127 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168);
}

/// A certificate the person said to trust for one server, by its SHA-256
/// fingerprint. Never used for any other host.
class TrustedCertificate {
  const TrustedCertificate({required this.host, required this.sha256});

  final String host;

  /// Upper-case hex, no separators.
  final String sha256;

  static TrustedCertificate? fromJson(Object? json) {
    if (json is! Map) return null;
    final host = json['host'];
    final sha = json['sha256'];
    if (host is! String || sha is! String) return null;
    return TrustedCertificate(host: host, sha256: sha.toUpperCase());
  }

  Map<String, Object?> toJson() => {'host': host, 'sha256': sha256};

  /// Whether this trusts exactly [fingerprint] on [onHost].
  bool trusts(String onHost, String fingerprint) =>
      onHost.toLowerCase() == host.toLowerCase() &&
      fingerprint.toUpperCase() == sha256;
}

/// [bytes] (a SHA-256 digest) as upper-case hex.
String hexFingerprint(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')]
        .join()
        .toUpperCase();

/// A fingerprint as people compare it: pairs of hex digits with colons,
/// such as `3F:A9:12:…`.
String spacedFingerprint(String hex) {
  final pairs = <String>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    pairs.add(hex.substring(i, i + 2));
  }
  return pairs.join(':').toUpperCase();
}

/// Whether Firefly III [version] (such as `6.7.9`) is new enough: 6.0 or
/// later. A version that does not read as one is refused.
bool isSupportedFireflyVersion(String version) {
  final major = int.tryParse(
    RegExp(r'^v?(\d+)\.').firstMatch(version.trim())?.group(1) ?? '',
  );
  return major != null && major >= 6;
}

/// How long ago [at] was, for "last sent 2 min ago": `just now`,
/// `2 min ago`, `3 hours ago`, `yesterday`, `3 days ago`.
String sentAgoLabel(DateTime at, DateTime now) {
  final gap = now.difference(at);
  if (gap.inMinutes < 1) return 'just now';
  if (gap.inMinutes < 60) return '${gap.inMinutes} min ago';
  if (gap.inHours < 24) {
    return gap.inHours == 1 ? '1 hour ago' : '${gap.inHours} hours ago';
  }
  final days = gap.inDays;
  if (days == 1) return 'yesterday';
  return '$days days ago';
}
