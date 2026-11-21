import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../routing/app_routes.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/marks.dart';
import '../../../theme/brand_tokens.dart';
import '../../../theme/layout.dart';
import '../../../theme/pesa_colors.dart';
import '../application/battery_providers.dart';
import '../domain/battery_prompt.dart';

/// "Keep Pesa Clarity awake": the steps to stop the battery saver putting
/// the app to sleep, then "All set" once the phone says it no longer does.
Future<void> showBatterySheet(BuildContext context) =>
    showAppSheet<void>(context: context, builder: (_) => const BatterySheet());

class BatterySheet extends ConsumerStatefulWidget {
  const BatterySheet({super.key});

  @override
  ConsumerState<BatterySheet> createState() => _BatterySheetState();
}

class _BatterySheetState extends ConsumerState<BatterySheet> {
  late final AppLifecycleListener _lifecycle;
  bool _couldNotOpen = false;

  @override
  void initState() {
    super.initState();
    // Back from Settings: ask again, so the sheet can say it is fixed.
    _lifecycle = AppLifecycleListener(onResume: () => recheckBattery(ref));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _openSettings() async {
    final opened = await ref.read(batterySourceProvider).openSettings();
    if (mounted) setState(() => _couldNotOpen = !opened);
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(batteryStatusProvider).value;
    // Only a definite answer counts: while unknown, the steps stay.
    if (status != null && !status.restricted) return const _AllSet();
    final text = BatterySteps.forPhone(status);
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    return SheetBody(
      title: 'Keep Pesa Clarity awake',
      subtitle: text.intro,
      children: [
        for (final (i, step) in text.steps.indexed)
          _StepRow(number: i + 1, step: step, first: i == 0),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('battery-open-settings'),
          onPressed: _openSettings,
          child: const Text('Open battery settings'),
        ),
        if (_couldNotOpen) ...[
          const SizedBox(height: 12),
          const Notice(
            'Settings did not open. Open Settings on your phone and follow '
            'the steps above.',
            tone: Tone.warning,
          ),
        ],
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                Icons.lock_outline,
                size: 16,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Pesa Clarity only reads messages from the senders you chose.',
                style: theme.textTheme.bodySmall!.copyWith(
                  color: colors.textMuted,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A numbered step: its title, where to go in Settings, and a line more.
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.number,
    required this.step,
    required this.first,
  });

  final int number;
  final BatteryStep step;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    final muted = theme.textTheme.bodyMedium!.copyWith(color: colors.textMuted);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(top: 1),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.border,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: theme.textTheme.titleSmall!.copyWith(
                fontFamily: BrandTokens.displayFont,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.title,
                  style: theme.textTheme.bodyLarge!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (step.path.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SettingsPath(step.path),
                ],
                if (step.detail case final detail?) ...[
                  SizedBox(height: step.path.isEmpty ? 2 : 6),
                  Text(detail, style: muted),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Settings › Apps › Pesa Clarity" in a field-coloured box. Each place
/// stays on one line; the path breaks only after a ›.
class SettingsPath extends StatelessWidget {
  const SettingsPath(this.places, {super.key});

  final List<String> places;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    final style = theme.textTheme.bodyMedium!.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.55,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.field,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text.rich(
        TextSpan(
          style: style,
          children: [
            for (final (i, place) in places.indexed) ...[
              if (i > 0)
                TextSpan(
                  text: ' › ',
                  style: TextStyle(
                    color: colors.textMuted,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              TextSpan(text: place.replaceAll(' ', ' ')),
            ],
          ],
        ),
        semanticsLabel: places.join(', then '),
      ),
    );
  }
}

/// The phone no longer puts the app to sleep.
class _AllSet extends StatelessWidget {
  const _AllSet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    return SheetBody(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            key: const Key('battery-all-set'),
            width: 56,
            height: 56,
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              color: colors.successSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.check, size: 30, color: colors.success),
          ),
        ),
        const SizedBox(height: 16),
        Semantics(
          header: true,
          child: Text('All set', style: theme.textTheme.headlineSmall),
        ),
        const SizedBox(height: 6),
        Text(
          'Pesa Clarity can now read new messages as they arrive.',
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            key: const Key('battery-read-again'),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: Layout.cardPadding,
              vertical: 2,
            ),
            leading: const Icon(Icons.refresh),
            minLeadingWidth: 24,
            title: const Text('Read messages again'),
            subtitle: const Text('Picks up anything it missed'),
            trailing: Icon(
              Icons.chevron_right,
              size: 20,
              color: colors.textMuted,
            ),
            // "Read messages again" lives with the accounts it reads.
            onTap: () {
              final router = GoRouter.of(context);
              Navigator.of(context).pop();
              router.go(AppRoutes.chooseAccounts);
            },
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('battery-done'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
