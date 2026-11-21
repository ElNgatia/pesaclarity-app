import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/layout.dart';
import '../../../theme/pesa_colors.dart';
import '../application/battery_providers.dart';
import 'battery_sheet.dart';

/// "Messages may be missed", under Home's lead card while the phone's
/// battery saver may put the app to sleep (Android only). "Fix this" opens
/// the steps; "Not now" hides it for a week. The phone is asked again each
/// time the app comes back to the front, so the card goes once it is fixed.
class BatteryHomeCard extends ConsumerStatefulWidget {
  const BatteryHomeCard({super.key});

  @override
  ConsumerState<BatteryHomeCard> createState() => _BatteryHomeCardState();
}

class _BatteryHomeCardState extends ConsumerState<BatteryHomeCard> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => recheckBattery(ref));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(batteryCardShownProvider)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: Layout.cardGap),
      child: BatteryCard(
        onFix: () => showBatterySheet(context),
        onNotNow: () => ref.read(batteryPromptProvider.notifier).notNow(),
      ),
    );
  }
}

/// The card itself: a battery in a warning tile, what is wrong, and two
/// buttons.
class BatteryCard extends StatelessWidget {
  const BatteryCard({required this.onFix, required this.onNotNow, super.key});

  final VoidCallback onFix;
  final VoidCallback onNotNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    return Card(
      key: const Key('home-battery'),
      child: Padding(
        padding: const EdgeInsets.all(Layout.cardPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colors.warningSoft,
                borderRadius: BorderRadius.circular(12),
              ),
              // A battery lying on its side, as in the phone's own settings.
              child: RotatedBox(
                quarterTurns: 1,
                child: Icon(
                  Icons.battery_1_bar,
                  size: 22,
                  color: colors.warning,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Messages may be missed',
                    style: theme.textTheme.bodyLarge!.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "Your phone's battery saver puts Pesa Clarity to sleep, "
                    'so new M-Pesa and bank messages may not show up.',
                    style: theme.textTheme.bodyMedium!.copyWith(
                      color: colors.textMuted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton(
                        key: const Key('home-battery-fix'),
                        onPressed: onFix,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                        child: const Text('Fix this'),
                      ),
                      TextButton(
                        key: const Key('home-battery-not-now'),
                        onPressed: onNotNow,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        child: const Text('Not now'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
