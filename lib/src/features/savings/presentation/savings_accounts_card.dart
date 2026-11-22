import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../domain/savings/savings_account.dart';
import '../../../domain/time/calendar.dart';
import '../../../shared/widgets/amounts_hidden.dart';
import '../../../shared/widgets/marks.dart';
import '../../../shared/widgets/sections.dart';
import '../../../theme/app_typography.dart';
import '../../../theme/layout.dart';
import '../../../theme/pesa_colors.dart';
import '../../debts/presentation/due_line.dart' show IconLine;
import '../application/savings_providers.dart';
import 'add_savings_sheet.dart';
import 'savings_account_screen.dart';
import 'savings_text.dart';

/// My accounts' "Savings apps" card: each savings account the app keeps,
/// such as Chumz, with what it holds and its goals, opening its page. The
/// money is held outside M-Pesa, so it has a card of its own. Nothing when
/// there are none.
class SavingsAccountsCard extends ConsumerWidget {
  const SavingsAccountsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // M-Pesa's own, such as M-Shwari, sit under M-Pesa (decision 0026).
    final accounts = <SavingsAccountSummary>[
      for (final a
          in ref.watch(savingsAccountsProvider).value ??
              const <SavingsAccountSummary>[])
        if (!(a.product?.inMpesaFamily ?? false)) a,
    ];
    if (accounts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    final today = CalendarDate.local(ref.watch(clockProvider)());
    final muted = theme.textTheme.bodySmall!.copyWith(color: colors.textMuted);
    final currencies = {for (final a in accounts) a.currency};
    final total = accounts.fold(0, (sum, a) => sum + a.balanceMinor);
    return Padding(
      padding: const EdgeInsets.only(top: Layout.cardGap),
      child: Card(
        key: const Key('savings-apps'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionLabel(
              SavingsText.savingsApps,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
              trailing: currencies.length == 1
                  ? Text(
                      shownMoney(
                        context,
                        total,
                        currency: currencies.single,
                        withCurrency: false,
                      ),
                      style: theme.textTheme.bodyMedium!.copyWith(
                        color: colors.textMuted,
                      ),
                    )
                  : null,
            ),
            for (final (i, a) in accounts.indexed) ...[
              if (i > 0) const Divider(height: 1),
              _AccountRow(account: a, today: today),
            ],
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: IconLine(
                icon: Icons.phone_android,
                iconSize: 16,
                gap: 8,
                text: TextSpan(text: SavingsText.fedBy(accounts.first.product)),
                style: muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.account, required this.today});

  final SavingsAccountSummary account;
  final CalendarDate today;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    return InkWell(
      key: Key('savings-account-${account.accountId}'),
      onTap: () => showSavingsAccount(context, account.accountId),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 9, 12, 9),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      SavingsText.rowName(account.name, account.product),
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      // A fund with one balance, such as Etica MMF.
                      account.product?.goalsByCode ?? true
                          ? SavingsText.goalsLine(
                              account.pockets.length,
                              account.lockedCount(today),
                            )
                          : account.product!.invested
                          ? SavingsText.invested
                          : SavingsText.saved,
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Layout.cardGap),
              Text(
                shownMoney(
                  context,
                  account.balanceMinor,
                  currency: account.currency,
                ),
                style: AppTypography.rowAmount(theme.colorScheme.onSurface),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, color: colors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// On Add or remove accounts: a savings app, such as Chumz, to add, for
/// one whose question was answered "It's not mine" or never asked. Nothing
/// when there is none to add.
class SavingsAddCard extends ConsumerWidget {
  const SavingsAddCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(savingsToAddProvider).value ?? const [];
    if (products.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Layout.cardGap),
      child: Card(
        key: const Key('savings-add'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionLabel(
              SavingsText.savingsApps,
              padding: EdgeInsets.fromLTRB(16, 14, 16, 2),
            ),
            for (final (i, product) in products.indexed) ...[
              if (i > 0) const Divider(height: 1),
              ListTile(
                key: Key('savings-add-${product.id}'),
                title: Text(SavingsText.rowName(product.name, product)),
                subtitle: Text(SavingsText.addAgain(product)),
                trailing: PillButton(
                  label: SavingsText.addButton,
                  icon: Icons.add,
                  tooltip: SavingsText.add(product),
                  onPressed: () => showAddSavingsSheet(context, product),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
