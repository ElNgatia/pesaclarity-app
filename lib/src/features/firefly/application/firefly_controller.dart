import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firefly_service.dart';
import 'firefly_settings.dart';

/// What the Firefly III screen shows.
class FireflyView {
  const FireflyView({
    required this.settings,
    required this.tokenSaved,
    required this.spaces,
    required this.waiting,
    required this.refused,
  });

  final FireflySettings settings;
  final bool tokenSaved;
  final List<FireflySpaceChoice> spaces;

  /// Changes waiting on the phone, across the spaces sent.
  final int waiting;

  /// Transactions Firefly III refused, with why.
  final List<FireflyRefusal> refused;
}

/// The Firefly III screen's state, read from every space on the phone.
class FireflyController extends AsyncNotifier<FireflyView> {
  FireflyService get _service => ref.read(fireflyServiceProvider);

  @override
  Future<FireflyView> build() => _load();

  Future<FireflyView> _load() async {
    final service = ref.read(fireflyServiceProvider);
    final waiting = await service.waiting();
    return FireflyView(
      settings: await service.settings(),
      tokenSaved: await service.tokenSaved(),
      spaces: await service.spaces(),
      waiting: waiting.waiting,
      refused: waiting.refused,
    );
  }

  /// Reads everything again, and Profile's row with it.
  Future<void> refresh() async {
    ref.invalidate(fireflySettingsProvider);
    state = AsyncData(await _load());
  }

  Future<FireflyCheck> check(String address, {String? token}) async {
    final result = await _service.check(address, token: token);
    await refresh();
    return result;
  }

  Future<void> confirmPlain(String address) async {
    await _service.confirmPlain(address);
    await refresh();
  }

  Future<void> trust(String host, String sha256) async {
    await _service.trust(host, sha256);
    await refresh();
  }

  Future<void> start(Set<String> spaceIds, FireflySendFrom from) async {
    await _service.start(spaceIds, from);
    await refresh();
  }

  Future<void> setSpace(FireflySpaceChoice choice, bool on) async {
    await _service.setSpace(choice.space, on);
    await refresh();
  }

  Future<void> setFrom(FireflySendFrom from) async {
    await _service.setFrom(from);
    await refresh();
  }

  /// Send now, or Try again; with [resendAll], Send everything again.
  Future<void> sendNow({bool resendAll = false}) async {
    await _service.sendQuietly(resendAll: resendAll);
    await refresh();
  }

  Future<void> turnOff() async {
    await _service.turnOff();
    await refresh();
  }
}

final fireflyControllerProvider =
    AsyncNotifierProvider.autoDispose<FireflyController, FireflyView>(
      FireflyController.new,
    );

/// The Firefly III settings alone, for Profile's row.
final fireflySettingsProvider = FutureProvider.autoDispose<FireflySettings>(
  (ref) => ref.read(fireflyServiceProvider).settings(),
);
