import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/savings_repository.dart';
import '../../../domain/savings/savings_prompt.dart';
import '../../../theme/brand_tokens.dart';
import '../../../theme/pesa_colors.dart';
import '../../debts/presentation/due_line.dart' show IconLine;
import 'add_savings_sheet.dart';
import 'savings_text.dart';

/// The payment a question is asked under, drawn as the top of a card that
/// [SavingsPromptCard] finishes, so the two read as one.
class SavingsPromptRow extends StatelessWidget {
  const SavingsPromptRow({required this.child, super.key});

  /// The payment's row, as Activity draws it.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? theme.colorScheme.surface,
        border: Border.all(color: PesaColors.of(context).border),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(BrandTokens.cardRadius),
        ),
      ),
      child: child,
    );
  }
}

/// "Is this your Chumz savings?", under the payment it is about: Add Chumz
/// opens the sheet that adds it, and "It's not mine" stops the question for
/// good, leaving the payment as it is.
class SavingsPromptCard extends ConsumerWidget {
  const SavingsPromptCard(this.prompt, {super.key});

  final SavingsPrompt prompt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    final product = prompt.product;
    // Drawn one pixel up, so its top edge is the row's bottom edge.
    return Transform.translate(
      offset: const Offset(0, -1),
      child: Container(
        key: const Key('savings-prompt'),
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: theme.cardTheme.color ?? theme.colorScheme.surface,
          border: Border.all(color: colors.border),
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(BrandTokens.cardRadius),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: IconLine(
                icon: Icons.account_balance_outlined,
                iconColor: colors.link,
                iconSize: 20,
                gap: 10,
                text: TextSpan(text: SavingsText.promptTitle(product)),
                style: theme.textTheme.titleMedium!,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              SavingsText.promptBody(product, prompt.paidTo),
              style: theme.textTheme.bodyMedium!.copyWith(
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: 14),
            _Buttons(
              primary: FilledButton(
                key: const Key('savings-prompt-add'),
                onPressed: () => showAddSavingsSheet(
                  context,
                  product,
                  promptedTransactionId: prompt.transactionId,
                ),
                child: Text(SavingsText.add(product)),
              ),
              secondary: OutlinedButton(
                key: const Key('savings-prompt-decline'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  await ref.read(savingsRepositoryProvider).decline(product.id);
                  messenger
                    ?..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(content: Text(SavingsText.declined(product))),
                    );
                },
                child: const Text(SavingsText.notMine),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two buttons sharing the width while both labels fit on one line; with
/// large text, one under the other.
class _Buttons extends StatelessWidget {
  const _Buttons({required this.primary, required this.secondary});

  final Widget primary;
  final Widget secondary;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(15) / 15;
      if (scale > 1.3 || constraints.maxWidth < 280) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [primary, const SizedBox(height: 8), secondary],
        );
      }
      return Row(
        children: [
          Expanded(child: primary),
          const SizedBox(width: 10),
          Expanded(child: secondary),
        ],
      );
    },
  );
}

/// The line shown once under the payment after the product was added:
/// "Chumz added · 4 older payments updated". Marks itself seen.
class SavingsAddedLine extends ConsumerStatefulWidget {
  const SavingsAddedLine(this.notice, {required this.name, super.key});

  final SavingsAddedNotice notice;

  /// The account's name, such as Chumz.
  final String name;

  @override
  ConsumerState<SavingsAddedLine> createState() => _SavingsAddedLineState();
}

class _SavingsAddedLineState extends ConsumerState<SavingsAddedLine> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(savingsRepositoryProvider).markAddedNoticeSeen());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    return Padding(
      key: const Key('savings-added'),
      padding: const EdgeInsetsDirectional.only(start: 58, bottom: 6),
      child: IconLine(
        icon: Icons.check_circle_outline,
        iconSize: 16,
        gap: 8,
        text: TextSpan(
          text: SavingsText.added(widget.name, widget.notice.updated),
        ),
        style: theme.textTheme.bodySmall!.copyWith(
          color: colors.successText,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
