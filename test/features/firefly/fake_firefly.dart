// A small stand-in for Firefly III's API on a local port, answering as
// Firefly III 6.7.9 did when it was tried in Docker (see
// test/fixtures/firefly): enough for the sender's paths, with switches for
// the problems it must handle.
import 'dart:convert';
import 'dart:io';

class FakeFirefly {
  FakeFirefly._(this._server);

  final HttpServer _server;

  /// Every request, as `METHOD /path`.
  final requests = <String>[];

  /// Bodies sent, by `METHOD /path`, newest last.
  final bodies = <String, List<Map<String, Object?>>>{};

  /// The token it takes.
  String token = 'made-up-token';

  /// Answer every call with this status, such as 503, or a redirect.
  int? failWith;

  /// Answer only these calls, by `METHOD /path`, with a status.
  final failOn = <String, int>{};

  /// External ids it refuses, as Firefly III refuses a transaction it
  /// cannot take.
  final refuse = <String>{};

  /// Wait this long before answering.
  Duration delay = Duration.zero;

  /// Accounts by id: name, type, balance.
  final accounts = <String, Map<String, Object?>>{};

  /// Transaction groups by id: the split as sent.
  final groups = <String, Map<String, Object?>>{};

  /// Groups the person deleted there.
  final deleted = <String>{};
  var _next = 100;

  /// Where it answers; kept after [close], for a server that went away.
  late final String url = 'http://127.0.0.1:${_server.port}';

  static Future<FakeFirefly> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeFirefly._(server);
    fake.url;
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final key = '${request.method} $path';
    requests.add(key);
    final text = await utf8.decodeStream(request);
    final body = text.isEmpty ? null : jsonDecode(text) as Map<String, Object?>;
    if (body != null) bodies.putIfAbsent(key, () => []).add(body);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final response = request.response;
    Future<void> send(int status, [Object? json]) async {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      if (json != null) response.write(jsonEncode(json));
      await response.close();
    }

    final fail = failWith ?? failOn[key];
    if (fail != null) {
      if (fail >= 300 && fail < 400) {
        response.headers.set('location', 'https://elsewhere.example/login');
      }
      return send(fail, {'message': 'Failing on purpose.'});
    }
    if (request.headers.value('authorization') != 'Bearer $token') {
      return send(401, {
        'message': 'Unauthenticated.',
        'exception': 'AuthenticationException',
      });
    }
    final parts = path.split('/');
    switch ((request.method, path)) {
      case ('GET', '/api/v1/about'):
        return send(200, {
          'data': {
            'version': '6.7.9',
            'api_version': '6.7.9',
            'php_version': '8.5.12',
            'os': 'Linux',
            'driver': 'sqlite',
          },
        });
      case ('GET', '/api/v1/about/user'):
        return send(200, {
          'data': {
            'type': 'users',
            'id': '1',
            'attributes': {'email': 'someone@example.com', 'role': 'owner'},
          },
        });
      case ('GET', final p) when p.startsWith('/api/v1/currencies/'):
        return send(200, {
          'data': {
            'id': '42',
            'attributes': {'code': parts.last, 'enabled': true},
          },
        });
      case ('GET', '/api/v1/search/accounts'):
        final query = request.uri.queryParameters['query'] ?? '';
        return send(200, {
          'data': [
            for (final MapEntry(:key, :value) in accounts.entries)
              if ((value['name']! as String).contains(query))
                {'id': key, 'attributes': value},
          ],
        });
      case ('POST', '/api/v1/accounts'):
        final id = '${_next++}';
        accounts[id] = {
          'name': body!['name'],
          'type': body['type'] == 'liability' ? 'liabilities' : body['type'],
          'current_balance': '0',
        };
        return send(200, {
          'data': {'id': id, 'attributes': accounts[id]},
        });
      case ('PUT', final p) when p.startsWith('/api/v1/accounts/'):
        return send(200, {
          'data': {'id': parts.last, 'attributes': accounts[parts.last]},
        });
      case ('POST', '/api/v1/transactions'):
        final split =
            (body!['transactions']! as List).single as Map<String, Object?>;
        final external = split['external_id'];
        for (final MapEntry(:key, :value) in groups.entries) {
          if (!deleted.contains(key) && value['external_id'] == external) {
            return send(422, {
              'message': 'Duplicate of transaction #$key.',
              'errors': {
                'transactions.0.description': [
                  'Duplicate of transaction #$key.',
                ],
              },
            });
          }
        }
        if (split['amount'] == '0.00' || refuse.contains(external)) {
          return send(422, {
            'message': 'The value must be more than zero.',
            'errors': {
              'transactions.0.amount': ['The value must be more than zero.'],
            },
          });
        }
        final id = '${_next++}';
        groups[id] = split;
        return send(200, {
          'data': {
            'id': id,
            'attributes': {
              'transactions': [
                {...split, 'transaction_journal_id': id},
              ],
            },
          },
        });
      case ('PUT', final p) when p.startsWith('/api/v1/transactions/'):
        final id = parts.last;
        if (!groups.containsKey(id) || deleted.contains(id)) {
          return send(404, {
            'message': 'Resource not found',
            'exception': 'NotFoundHttpException',
          });
        }
        final split =
            (body!['transactions']! as List).single as Map<String, Object?>;
        groups[id] = {...groups[id]!, ...split};
        return send(200, {
          'data': {
            'id': id,
            'attributes': {
              'transactions': [groups[id]],
            },
          },
        });
      case ('DELETE', final p) when p.startsWith('/api/v1/transactions/'):
        final id = parts.last;
        if (!groups.containsKey(id) || deleted.contains(id)) {
          return send(404, {'message': 'Resource not found'});
        }
        deleted.add(id);
        response.statusCode = 204;
        return response.close();
      case ('GET', '/api/v1/search/transactions'):
        final query = request.uri.queryParameters['query'] ?? '';
        final match = RegExp(r'^external_id_(is|starts):"(.*)"$')
            .firstMatch(query);
        final found = [
          if (match != null)
            for (final MapEntry(:key, :value) in groups.entries)
              if (!deleted.contains(key) &&
                  (match.group(1) == 'is'
                      ? value['external_id'] == match.group(2)
                      : (value['external_id'] as String? ?? '').startsWith(
                          match.group(2)!,
                        )))
                {
                  'id': key,
                  'attributes': {
                    'transactions': [value],
                  },
                },
        ];
        return send(200, {
          'data': found,
          'meta': {
            'pagination': {'total_pages': 1},
          },
        });
    }
    return send(404, {'message': 'Resource not found'});
  }

  /// The live groups' splits.
  List<Map<String, Object?>> get live => [
    for (final MapEntry(:key, :value) in groups.entries)
      if (!deleted.contains(key)) value,
  ];
}
