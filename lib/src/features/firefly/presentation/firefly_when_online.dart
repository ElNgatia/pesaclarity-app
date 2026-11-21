import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../routing/app_router.dart';
import '../application/firefly_service.dart';

/// Sends what waits for the person's own Firefly III (decision 0029,
/// section 5) once the app is unlocked and set up, and each time it comes
/// back to the front, as `BackupWhenOnline` does for backups. It shows
/// nothing: a problem is kept for the Firefly III screen, and offline it
/// tries again next time. With sending off it does nothing.
class FireflyWhenOnline extends ConsumerStatefulWidget {
  const FireflyWhenOnline({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<FireflyWhenOnline> createState() => _FireflyWhenOnlineState();
}

class _FireflyWhenOnlineState extends ConsumerState<FireflyWhenOnline> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _send);
    ref.listenManual(launchGateProvider, (_, gate) {
      if (gate.value ?? false) _send();
    }, fireImmediately: true);
  }

  void _send() {
    if (!mounted) return;
    // Every space is read; nothing is opened before unlock and setup.
    if (!(ref.read(launchGateProvider).value ?? false)) return;
    unawaited(
      ref
          .read(fireflyServiceProvider)
          .sendQuietly()
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
