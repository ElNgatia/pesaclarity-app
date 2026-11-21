import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/money/currency_data.dart';
import '../../../core/money/money.dart';
import '../../../domain/firefly/firefly_mapping.dart';
import '../../../domain/firefly/firefly_server.dart';

/// Why a call to Firefly III did not work. The token never appears in it.
sealed class FireflyException implements Exception {
  const FireflyException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The server did not answer: off, out of reach or too slow.
final class FireflyUnreachable extends FireflyException {
  const FireflyUnreachable(super.message);
}

/// Firefly III refused the token (401).
final class FireflyTokenRefused extends FireflyException {
  const FireflyTokenRefused() : super('The token was refused.');
}

/// The server's certificate is not one the phone trusts, nor the one the
/// person chose to trust. [sha256] is its fingerprint.
final class FireflyUntrustedCertificate extends FireflyException {
  const FireflyUntrustedCertificate(this.sha256)
    : super('The server uses a certificate this phone does not know.');

  final String sha256;
}

/// The address answered with a redirect, which is never followed, so the
/// token is never sent anywhere else.
final class FireflyRedirected extends FireflyException {
  const FireflyRedirected(this.location)
    : super('The address sends the app somewhere else.');

  final String? location;
}

/// Something answered that is not Firefly III's API.
final class FireflyNotFirefly extends FireflyException {
  const FireflyNotFirefly(super.message);
}

/// Firefly III is older than 6.0.
final class FireflyTooOld extends FireflyException {
  const FireflyTooOld(this.version)
    : super(
        'Firefly III $version is too old. Pesa Clarity needs 6.0 or later.',
      );

  final String version;
}

/// Firefly III refused what was sent (422), with its reason.
final class FireflyRejected extends FireflyException {
  const FireflyRejected(super.message, {this.duplicate = false});

  /// It already has this transaction (`error_if_duplicate_hash`).
  final bool duplicate;
}

/// What was asked for is not there (404), such as a transaction the person
/// deleted in Firefly III.
final class FireflyNotFound extends FireflyException {
  const FireflyNotFound() : super('Not found in Firefly III.');
}

/// The server failed (5xx) or answered something unreadable.
final class FireflyServerError extends FireflyException {
  const FireflyServerError(super.message);
}

/// What `GET /api/v1/about` says.
class FireflyAbout {
  const FireflyAbout({required this.version, required this.apiVersion});

  final String version;
  final String apiVersion;
}

/// Calls the person's own Firefly III over its REST API (decision 0029),
/// with their personal access token. Each call opens a client from
/// [connect], which reaches only that server; redirects are never
/// followed.
class FireflyClient {
  FireflyClient({
    required this.server,
    required this._token,
    required this._connect,
    this.timeout = const Duration(seconds: 20),
  });

  final FireflyServerAddress server;
  final String _token;
  final HttpClient Function(void Function(String sha256) onUntrusted) _connect;
  final Duration timeout;

  HttpClient? _client;
  String? _untrusted;

  HttpClient get _http => _client ??= _connect((sha) => _untrusted = sha);

  /// Closes the connection.
  void close() {
    _client?.close(force: true);
    _client = null;
  }

  /// Firefly III's version. Refuses anything that is not Firefly III 6 or
  /// later.
  Future<FireflyAbout> about() async {
    final json = await _call('GET', '/api/v1/about');
    final data = json is Map ? json['data'] : null;
    final version = data is Map ? data['version'] : null;
    if (version is! String) {
      throw const FireflyNotFirefly(
        'The address did not answer as Firefly III.',
      );
    }
    if (!isSupportedFireflyVersion(version)) throw FireflyTooOld(version);
    final api = data is Map ? data['api_version'] : null;
    return FireflyAbout(version: version, apiVersion: api is String ? api : '');
  }

  /// The email of the user the token is for, so a token with no rights
  /// fails here rather than later.
  Future<String> user() async {
    final json = await _call('GET', '/api/v1/about/user');
    final email = _attributes(json)['email'];
    if (email is! String) {
      throw const FireflyNotFirefly(
        'The address did not answer as Firefly III.',
      );
    }
    return email;
  }

  /// Makes [code] usable: Firefly III ships without some currencies, such
  /// as KES, and with most turned off.
  Future<void> ensureCurrency(String code) async {
    try {
      final json = await _call('GET', '/api/v1/currencies/$code');
      if (_attributes(json)['enabled'] != true) {
        await _call('POST', '/api/v1/currencies/$code/enable', body: {});
      }
    } on FireflyNotFound {
      final digits = minorUnitDigits(code);
      try {
        await _call(
          'POST',
          '/api/v1/currencies',
          body: {
            'code': code,
            'name': currencyCatalogue[code]?.name ?? code,
            'symbol': code,
            'decimal_places': digits,
            'enabled': true,
          },
        );
      } on FireflyRejected {
        // Made meanwhile, or its symbol is taken: enabling is enough.
        await _call('POST', '/api/v1/currencies/$code/enable', body: {});
      }
    }
  }

  static String _type(FireflyAccountKind kind) => switch (kind) {
    FireflyAccountKind.asset => 'asset',
    FireflyAccountKind.liability => 'liabilities',
    FireflyAccountKind.expense => 'expense',
    FireflyAccountKind.revenue => 'revenue',
  };

  /// The id of the account of [kind] named exactly [name], if there is
  /// one. Firefly III's search matches parts of names, so the name is
  /// checked here.
  Future<String?> findAccount(String name, FireflyAccountKind kind) async {
    final json = await _call(
      'GET',
      '/api/v1/search/accounts',
      query: {'query': name, 'field': 'name', 'type': _type(kind)},
    );
    final data = json is Map ? json['data'] : null;
    if (data is! List) return null;
    for (final item in data) {
      if (item is! Map) continue;
      final attributes = item['attributes'];
      if (attributes is Map &&
          attributes['name'] == name &&
          _sameKind(attributes['type'], kind)) {
        final id = item['id'];
        if (id is String) return id;
      }
    }
    return null;
  }

  static bool _sameKind(Object? type, FireflyAccountKind kind) =>
      switch (kind) {
        FireflyAccountKind.liability => type == 'liabilities',
        _ => type == _type(kind),
      };

  Map<String, Object?> _accountBody(
    FireflyAccountSpec spec, {
    int? openingMinor,
    String? openingDate,
  }) {
    final digits = minorUnitDigits(spec.currency ?? 'KES');
    final liability = spec.kind == FireflyAccountKind.liability;
    return {
      'name': spec.name,
      'type': switch (spec.kind) {
        FireflyAccountKind.liability => 'liability',
        final kind => _type(kind),
      },
      'account_role': ?spec.role,
      'currency_code': ?spec.currency,
      if (liability) ...{
        'liability_type': spec.liabilityType ?? 'loan',
        'liability_direction': 'debit',
        'interest': '0',
        'interest_period': 'monthly',
      },
      if (openingMinor != null && openingDate != null && spec.isOwn) ...{
        'opening_balance': fireflyAmount(openingMinor, digits),
        'opening_balance_date': openingDate,
      },
      'notes': 'Sent by Pesa Clarity.',
    };
  }

  /// Makes the account [spec], opening with [openingMinor] on
  /// [openingDate] (`2026-01-01`) when it is an asset or liability.
  Future<String> createAccount(
    FireflyAccountSpec spec, {
    int? openingMinor,
    String? openingDate,
  }) async {
    final json = await _call(
      'POST',
      '/api/v1/accounts',
      body: _accountBody(
        spec,
        openingMinor: openingMinor,
        openingDate: openingDate,
      ),
    );
    return _id(json);
  }

  /// Changes account [id] to [spec] and its opening balance.
  Future<void> updateAccount(
    String id,
    FireflyAccountSpec spec, {
    int? openingMinor,
    String? openingDate,
  }) => _call(
    'PUT',
    '/api/v1/accounts/$id',
    body: _accountBody(
      spec,
      openingMinor: openingMinor ?? (spec.isOwn ? 0 : null),
      openingDate: openingDate,
    ),
  );

  /// Account [id]'s current balance in minor units of [digits].
  Future<int?> accountBalance(String id, int digits) async {
    final json = await _call('GET', '/api/v1/accounts/$id');
    final balance = _attributes(json)['current_balance'];
    return fireflyMinor(balance is String ? balance : null, digits);
  }

  /// Makes a transaction from [split] and returns its group id. Duplicates
  /// are refused ([FireflyRejected.duplicate]).
  Future<String> createTransaction(Map<String, Object?> split) async {
    final json = await _call(
      'POST',
      '/api/v1/transactions',
      body: {
        'error_if_duplicate_hash': true,
        'apply_rules': true,
        'fire_webhooks': true,
        'transactions': [split],
      },
    );
    return _id(json);
  }

  /// Changes group [id] to [split]. Firefly III's rules do not run again.
  Future<void> updateTransaction(String id, Map<String, Object?> split) =>
      _call(
        'PUT',
        '/api/v1/transactions/$id',
        body: {
          'apply_rules': false,
          'fire_webhooks': true,
          'transactions': [split],
        },
      );

  /// Deletes group [id]. One already gone is fine.
  Future<void> deleteTransaction(String id) async {
    try {
      await _call('DELETE', '/api/v1/transactions/$id');
    } on FireflyNotFound {
      return;
    }
  }

  /// The group id of the transaction with [externalId], if there is one.
  Future<String?> findByExternalId(String externalId) async {
    final found = await _search('external_id_is:"$externalId"');
    return found[externalId];
  }

  /// Every transaction whose external id starts with [prefix], as group
  /// id by external id: to rebuild a lost record of what was sent.
  Future<Map<String, String>> findByExternalPrefix(String prefix) =>
      _search('external_id_starts:"$prefix"', all: true);

  Future<Map<String, String>> _search(String query, {bool all = false}) async {
    final out = <String, String>{};
    for (var page = 1; ; page++) {
      final json = await _call(
        'GET',
        '/api/v1/search/transactions',
        query: {'query': query, 'limit': '100', 'page': '$page'},
      );
      final data = json is Map ? json['data'] : null;
      if (data is! List) break;
      for (final item in data) {
        if (item is! Map) continue;
        final id = item['id'];
        final attributes = item['attributes'];
        final splits = attributes is Map ? attributes['transactions'] : null;
        if (id is! String || splits is! List) continue;
        for (final split in splits) {
          final external = split is Map ? split['external_id'] : null;
          if (external is String) out[external] ??= id;
        }
      }
      final meta = json is Map ? json['meta'] : null;
      final pagination = meta is Map ? meta['pagination'] : null;
      final total = pagination is Map ? pagination['total_pages'] : null;
      if (!all || total is! int || page >= total) break;
    }
    return out;
  }

  static Map<Object?, Object?> _attributes(Object? json) {
    final data = json is Map ? json['data'] : null;
    final attributes = data is Map ? data['attributes'] : null;
    return attributes is Map ? attributes : const {};
  }

  static String _id(Object? json) {
    final data = json is Map ? json['data'] : null;
    final id = data is Map ? data['id'] : null;
    if (id is! String) throw const FireflyServerError('No id in the answer.');
    return id;
  }

  /// Firefly III's reason, with each field it named: "The name field is
  /// required." alone does not say what was being made.
  static FireflyRejected _rejected(String method, String path, Object? json) {
    final message = json is Map && json['message'] is String
        ? json['message'] as String
        : 'Firefly III refused it.';
    final errors = json is Map ? json['errors'] : null;
    final details = [
      if (errors is Map)
        for (final MapEntry(:key, :value) in errors.entries)
          if (value is List && value.isNotEmpty) '$key: ${value.first}',
    ];
    final what = path.startsWith('/api/v1/accounts')
        ? 'An account'
        : path.startsWith('/api/v1/currencies')
        ? 'A currency'
        : 'A transaction';
    return FireflyRejected(
      details.isEmpty ? '$what: $message' : '$what: ${details.join('; ')}',
      duplicate: message.startsWith('Duplicate of transaction'),
    );
  }

  Future<Object?> _call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    final uri = server.resolve(path, query);
    _untrusted = null;
    final HttpClientResponse response;
    final String text;
    try {
      final request = await _http.openUrl(method, uri).timeout(timeout);
      request
        ..followRedirects = false
        ..maxRedirects = 0
        ..persistentConnection = true;
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $_token')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.api+json')
        // Firefly III wants it even on a POST with no body.
        ..set(HttpHeaders.contentTypeHeader, 'application/json');
      // With its length: a chunked body never reaches Firefly III behind
      // its own nginx.
      final bytes = body == null
          ? const <int>[]
          : utf8.encode(jsonEncode(body));
      request.contentLength = bytes.length;
      if (bytes.isNotEmpty) request.add(bytes);
      response = await request.close().timeout(timeout);
      text = await response.transform(utf8.decoder).join().timeout(timeout);
    } on HandshakeException {
      final sha = _untrusted;
      close();
      if (sha != null) throw FireflyUntrustedCertificate(sha);
      throw const FireflyUnreachable('The secure connection failed.');
    } on TimeoutException {
      close();
      throw const FireflyUnreachable('The server took too long to answer.');
    } on SocketException {
      close();
      throw const FireflyUnreachable('The server could not be reached.');
    } on HttpException {
      close();
      throw const FireflyUnreachable('The connection broke off.');
    }
    final status = response.statusCode;
    if (status >= 300 && status < 400) {
      throw FireflyRedirected(
        response.headers.value(HttpHeaders.locationHeader),
      );
    }
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      json = null;
    }
    if (status == 401) throw const FireflyTokenRefused();
    if (status == 404) throw const FireflyNotFound();
    if (status == 422 || status == 400) {
      throw _rejected(method, path, json);
    }
    if (status >= 400) {
      throw FireflyServerError('Firefly III answered $status.');
    }
    if (status != 204 && text.isNotEmpty && json == null) {
      throw const FireflyNotFirefly(
        'The address did not answer as Firefly III.',
      );
    }
    return json;
  }
}
