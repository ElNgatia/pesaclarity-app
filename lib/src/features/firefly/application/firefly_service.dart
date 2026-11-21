import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/pinned_http_client.dart';
import '../../../core/time/clock.dart';
import '../../../data/database/app_database.dart';
import '../../../data/database/space_databases.dart';
import '../../../data/repositories/app_settings_repository.dart';
import '../../../domain/firefly/firefly_server.dart';
import '../../../domain/spaces/space.dart';
import '../../../domain/time/calendar.dart';
import '../../security/data/secure_store.dart';
import '../data/firefly_client.dart';
import '../data/firefly_space_store.dart';
import 'firefly_sender.dart';
import 'firefly_settings.dart';

/// What Check connection found.
sealed class FireflyCheck {
  const FireflyCheck();
}

/// Connected: Firefly III [version] answered and took the token.
final class FireflyConnected extends FireflyCheck {
  const FireflyConnected(this.version);

  final String version;
}

/// Plain http on the home network: the person confirms it first.
final class FireflyNeedsPlainConfirm extends FireflyCheck {
  const FireflyNeedsPlainConfirm();
}

/// A certificate the phone does not know: the person is asked whether to
/// trust it, by its fingerprint.
final class FireflyAskTrust extends FireflyCheck {
  const FireflyAskTrust({required this.host, required this.sha256});

  final String host;
  final String sha256;
}

/// It did not work, with what to say and which field it is about.
final class FireflyCheckFailed extends FireflyCheck {
  const FireflyCheckFailed(this.message, {this.problem, this.token = false});

  final String message;
  final FireflyProblem? problem;

  /// The token is the problem, not the address.
  final bool token;
}

/// One space that can be sent, and whether it is.
typedef FireflySpaceChoice = ({Space space, bool sending});

/// A transaction Firefly III refused, with why.
typedef FireflyRefusal = ({String space, int transactionId, String reason});

/// Sending to the person's own Firefly III, across the spaces on the phone
/// (decision 0029). Screens go through [FireflyController]; the app's start
/// and return send quietly through [sendQuietly].
class FireflyService {
  FireflyService(this._ref);

  final Ref _ref;
  Future<void>? _running;

  AppSettingsRepository get _settingsRepo =>
      _ref.read(mainSettingsRepositoryProvider);
  SecureStore get _secure => _ref.read(secureStoreProvider);

  Future<FireflySettings> settings() async => FireflySettings.fromJson(
    await _settingsRepo.readJson(fireflySettingsKey),
  );

  Future<void> saveSettings(FireflySettings settings) =>
      _settingsRepo.writeJson(fireflySettingsKey, settings.toJson());

  Future<bool> tokenSaved() async =>
      (await _secure.read(fireflyTokenKey))?.isNotEmpty ?? false;

  Future<void> saveToken(String token) =>
      _secure.write(fireflyTokenKey, token.trim());

  /// A client for [address] with [token], trusting [trusted] only for its
  /// own host.
  FireflyClient client(
    FireflyServerAddress address,
    String token, {
    TrustedCertificate? trusted,
  }) {
    final factory = _ref.read(httpClientFactoryProvider);
    final pin = trusted != null && trusted.host == address.host
        ? trusted.sha256
        : null;
    return FireflyClient(
      server: address,
      token: token,
      connect: (onUntrusted) => factory.createForUserServer(
        address.base,
        trustedSha256: pin,
        onUntrusted: onUntrusted,
      ),
    );
  }

  /// Checks [addressText] with [token] (the saved one when null): Firefly
  /// III 6 or later must answer and take the token. A working address and
  /// token are saved; nothing is sent.
  Future<FireflyCheck> check(String addressText, {String? token}) async {
    final parsed = parseFireflyAddress(addressText);
    final address = parsed.address;
    if (address == null) return FireflyCheckFailed(parsed.problem!.message);
    var current = await settings();
    final sameAddress = current.address == address.toString();
    if (address.isPlain && !(sameAddress && current.plainConfirmed)) {
      return const FireflyNeedsPlainConfirm();
    }
    final key = (token == null || token.trim().isEmpty)
        ? await _secure.read(fireflyTokenKey)
        : token.trim();
    if (key == null || key.isEmpty) {
      return const FireflyCheckFailed(
        'Paste a personal access token.',
        token: true,
      );
    }
    final firefly = client(address, key, trusted: current.trusted);
    try {
      final about = await firefly.about();
      await firefly.user();
      current = current.copyWith(
        address: address.toString(),
        version: about.version,
        plainConfirmed: address.isPlain ? true : current.plainConfirmed,
        clearProblem: true,
      );
      await saveSettings(current);
      await saveToken(key);
      return FireflyConnected(about.version);
    } on FireflyUntrustedCertificate catch (e) {
      return FireflyAskTrust(host: address.host, sha256: e.sha256);
    } on FireflyTokenRefused {
      return const FireflyCheckFailed(
        'The saved token was refused.',
        problem: FireflyProblem.tokenRefused,
        token: true,
      );
    } on FireflyException catch (e) {
      return FireflyCheckFailed(_say(e, address.host), problem: _problem(e));
    } finally {
      firefly.close();
    }
  }

  /// The person confirmed plain http for [addressText].
  Future<void> confirmPlain(String addressText) async {
    final address = parseFireflyAddress(addressText).address;
    if (address == null) return;
    await saveSettings(
      (await settings()).copyWith(
        address: address.toString(),
        plainConfirmed: true,
      ),
    );
  }

  /// The person chose to trust the certificate with [sha256] on [host].
  Future<void> trust(String host, String sha256) async => saveSettings(
    (await settings()).copyWith(
      trusted: TrustedCertificate(host: host, sha256: sha256),
    ),
  );

  /// The spaces on the phone and whether each is sent.
  Future<List<FireflySpaceChoice>> spaces() async {
    final databases = _ref.read(spaceDatabasesProvider);
    final out = <FireflySpaceChoice>[];
    for (final space in await databases.listed()) {
      final sending = await _inSpace(
        space,
        (db) => FireflySpaceStore(db).sending(),
      );
      out.add((space: space, sending: sending ?? false));
    }
    return out;
  }

  /// Runs [work] on [space]'s database; null when it cannot open.
  Future<T?> _inSpace<T>(
    Space space,
    Future<T> Function(AppDatabase db) work,
  ) async {
    final (db, close) = await _ref.read(spaceDatabasesProvider).open(space.id);
    try {
      return await work(db);
    } finally {
      if (close) await db.close();
    }
  }

  /// Changes waiting across the spaces sent, and those Firefly III refused.
  Future<({int waiting, List<FireflyRefusal> refused})> waiting() async {
    var count = 0;
    final refused = <FireflyRefusal>[];
    for (final (:space, :sending) in await spaces()) {
      if (!sending) continue;
      await _inSpace(space, (db) async {
        final store = FireflySpaceStore(db);
        count += await store.waitingCount();
        for (final row in await store.refused()) {
          refused.add((
            space: space.name,
            transactionId: row.transactionId,
            reason: row.lastError ?? 'Firefly III refused it.',
          ));
        }
      });
    }
    return (waiting: count, refused: refused);
  }

  /// How many transactions [spaceIds] have from [from] on: what a first
  /// send makes.
  Future<int> countToSend(Set<String> spaceIds, CalendarDate from) async {
    var count = 0;
    for (final (:space, sending: _) in await spaces()) {
      if (!spaceIds.contains(space.id)) continue;
      await _inSpace(space, (db) async {
        final n = db.transactions.id.count();
        final row =
            await (db.selectOnly(db.transactions)
                  ..addColumns([n])
                  ..where(
                    db.transactions.occurredAt.isBiggerOrEqualValue(
                      from.startInstant,
                    ),
                  ))
                .getSingle();
        count += row.read(n) ?? 0;
      });
    }
    return count;
  }

  /// Starts sending [spaceIds] from [sendFrom]'s day, then sends.
  Future<void> start(Set<String> spaceIds, FireflySendFrom sendFrom) async {
    final today = CalendarDate.local(_ref.read(clockProvider)());
    for (final (:space, sending: _) in await spaces()) {
      await _inSpace(
        space,
        (db) => FireflySpaceStore(db).setSending(spaceIds.contains(space.id)),
      );
    }
    await saveSettings(
      (await settings()).copyWith(
        on: true,
        sendFrom: sendFrom,
        fromDay: fireflyFromDay(sendFrom, today),
      ),
    );
    unawaited(sendQuietly());
  }

  /// Sends [space] or stops sending it.
  Future<void> setSpace(Space space, bool on) async {
    await _inSpace(space, (db) => FireflySpaceStore(db).setSending(on));
    if (on) unawaited(sendQuietly());
  }

  /// Moves Send from. Earlier sends the older transactions and changes the
  /// opening balances; later deletes there what is now before it.
  Future<void> setFrom(FireflySendFrom sendFrom) async {
    final today = CalendarDate.local(_ref.read(clockProvider)());
    await saveSettings(
      (await settings()).copyWith(
        sendFrom: sendFrom,
        fromDay: fireflyFromDay(sendFrom, today),
      ),
    );
    unawaited(sendQuietly());
  }

  /// Turns sending off: the token and the changes waiting are removed from
  /// this phone. What is in Firefly III stays there, and so does the
  /// record of what was sent, so turning on again sends nothing twice.
  Future<void> turnOff() async {
    await _running;
    await _secure.delete(fireflyTokenKey);
    for (final (:space, sending: _) in await spaces()) {
      await _inSpace(space, (db) => FireflySpaceStore(db).setSending(false));
    }
    await saveSettings(
      (await settings()).copyWith(
        on: false,
        clearProblem: true,
        clearLastSent: true,
      ),
    );
  }

  /// Sends what waits, when sending is on. Problems are kept for the
  /// Firefly III screen and shown nowhere else. One run at a time.
  Future<void> sendQuietly({bool resendAll = false}) {
    final running = _running;
    if (running != null) return running;
    return _running = _send(resendAll: resendAll)
        .whenComplete(() => _running = null);
  }

  Future<void> _send({required bool resendAll}) async {
    final settings = await this.settings();
    final address = settings.server;
    final token = await _secure.read(fireflyTokenKey);
    if (!settings.on || address == null || token == null || token.isEmpty) {
      return;
    }
    if (settings.problem == FireflyProblem.tokenRefused) return;
    final firefly = client(address, token, trusted: settings.trusted);
    final clock = _ref.read(clockProvider);
    final from =
        (settings.fromDay ??
                fireflyFromDay(settings.sendFrom, CalendarDate.local(clock())))
            .startInstant;
    try {
      // One cheap call first: offline, it stops here until next time.
      final about = await firefly.about();
      final sender = FireflySender(
        client: firefly,
        from: from,
        offset: UserTimeZone.currentOffset,
        clock: clock,
      );
      for (final (:space, :sending) in await spaces()) {
        if (!sending) continue;
        await _inSpace(
          space,
          (db) => sender.sendSpace(space, db, resendAll: resendAll),
        );
      }
      await saveSettings(
        (await this.settings()).copyWith(
          lastSentAt: clock(),
          version: about.version,
          clearProblem: true,
        ),
      );
    } on FireflyException catch (e) {
      await saveSettings(
        (await this.settings()).copyWith(problem: _problem(e)),
      );
    } on Object catch (e) {
      // Best effort: tried again on the next start or return. Never the
      // token, which no error carries.
      if (kDebugMode) debugPrint('Sending to Firefly III stopped: $e');
    } finally {
      firefly.close();
    }
  }

  static FireflyProblem _problem(FireflyException e) => switch (e) {
    FireflyTokenRefused() => FireflyProblem.tokenRefused,
    FireflyUntrustedCertificate() => FireflyProblem.certificate,
    FireflyRedirected() => FireflyProblem.redirected,
    FireflyNotFirefly() || FireflyTooOld() => FireflyProblem.notFirefly,
    _ => FireflyProblem.unreachable,
  };

  static String _say(FireflyException e, String host) => switch (e) {
    FireflyUnreachable() =>
      "Can't reach $host. Is the server on, and is this phone on its "
          'network?',
    FireflyRedirected() =>
      'This address sends the app somewhere else. Type the address Firefly '
          'III itself is at.',
    FireflyTooOld(:final version) =>
      'This is Firefly III $version. Pesa Clarity needs 6.0 or later.',
    FireflyNotFirefly() => "This address doesn't answer as Firefly III.",
    FireflyTokenRefused() => 'The saved token was refused.',
    FireflyUntrustedCertificate() =>
      '$host uses a certificate this phone doesn\'t know.',
    _ => "Firefly III didn't answer as expected. Try again.",
  };
}

final fireflyServiceProvider = Provider<FireflyService>(FireflyService.new);
