import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';
import 'package:pesaclarity/src/features/firefly/application/firefly_service.dart';
import 'package:pesaclarity/src/features/firefly/application/firefly_settings.dart';

/// Made-up spaces for the Firefly III screens.
const fireflySpaces = [
  Space.personal,
  Space(id: 'shop', name: 'Green Basket Grocers', kind: SpaceKind.business),
];

/// A [FireflyService] that keeps everything in memory and answers Check
/// connection with [checks], in turn, for the screens' tests.
class FakeFireflyService extends FireflyService {
  FakeFireflyService(
    super.ref, {
    this.current = const FireflySettings(),
    this.token = false,
    this.waitingCount = 0,
    List<FireflyCheck>? checks,
    Map<String, bool>? sending,
  }) : checks = checks ?? const [FireflyConnected('6.7.9')],
       sending = sending ?? {for (final s in fireflySpaces) s.id: false};

  FireflySettings current;
  bool token;
  int waitingCount;
  final List<FireflyCheck> checks;
  final Map<String, bool> sending;
  var _check = 0;
  final calls = <String>[];

  @override
  Future<FireflySettings> settings() async => current;

  @override
  Future<void> saveSettings(FireflySettings settings) async =>
      current = settings;

  @override
  Future<bool> tokenSaved() async => token;

  @override
  Future<List<FireflySpaceChoice>> spaces() async => [
    for (final s in fireflySpaces) (space: s, sending: sending[s.id] ?? false),
  ];

  @override
  Future<({int waiting, List<FireflyRefusal> refused})> waiting() async =>
      (waiting: waitingCount, refused: const <FireflyRefusal>[]);

  @override
  Future<int> countToSend(Set<String> spaceIds, CalendarDate from) async =>
      spaceIds.length * 1158;

  @override
  Future<FireflyCheck> check(String addressText, {String? token}) async {
    calls.add('check $addressText');
    final result = checks[_check.clamp(0, checks.length - 1)];
    _check++;
    if (result is FireflyConnected) {
      current = current.copyWith(address: addressText, version: '6.7.9');
      this.token = true;
    }
    return result;
  }

  @override
  Future<void> confirmPlain(String addressText) async =>
      calls.add('plain $addressText');

  @override
  Future<void> trust(String host, String sha256) async =>
      calls.add('trust $host $sha256');

  @override
  Future<void> start(Set<String> spaceIds, FireflySendFrom sendFrom) async {
    calls.add('start ${(spaceIds.toList()..sort()).join(',')} $sendFrom');
    for (final id in spaceIds) {
      sending[id] = true;
    }
    current = current.copyWith(on: true, sendFrom: sendFrom);
  }

  @override
  Future<void> sendQuietly({bool resendAll = false}) async =>
      calls.add(resendAll ? 'send all' : 'send');

  @override
  Future<void> turnOff() async {
    calls.add('off');
    token = false;
    waitingCount = 0;
    current = current.copyWith(on: false);
  }
}

/// [fake] in place of the real service.
Override fakeFireflyService(FakeFireflyService Function(Ref ref) fake) =>
    fireflyServiceProvider.overrideWith(fake);
