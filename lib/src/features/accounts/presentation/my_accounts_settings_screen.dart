import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money/currency_data.dart';
import '../../../core/money/money.dart';
import '../../../data/database/app_database.dart' hide Tag;
import '../../../data/database/database_providers.dart';
import '../../../domain/accounts/account_reference.dart';
import '../../../domain/accounts/mpesa_lines.dart';
import '../../../domain/spaces/space.dart';
import '../../../routing/app_routes.dart';
import '../../../shared/semantic_ids.dart';
import '../../../shared/widgets/amounts_hidden.dart';
import '../../../shared/widgets/marks.dart';
import '../../../shared/widgets/states.dart';
import '../../../theme/layout.dart';
import '../../../theme/pesa_colors.dart';
import '../../activity/application/activity_providers.dart';
import '../../currency/application/currency_controller.dart';
import '../../savings/presentation/savings_accounts_card.dart';
import '../../spaces/application/spaces_providers.dart';
import '../application/mpesa_family_providers.dart';
import '../application/mpesa_lines_providers.dart';
import '../domain/institution.dart';
import 'account_currency_screen.dart';
import 'line_questions.dart';
import 'mpesa_family_card.dart';
import 'mpesa_lines_sheet.dart';

/// Profile › My accounts: each account and the currency it counts in, the
/// savings apps the app keeps, such as Chumz, and the way to add or remove
/// accounts.
class MyAccountsSettingsScreen extends ConsumerWidget {
  const MyAccountsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    final base =
        ref.watch(currencyControllerProvider).value?.base ?? BaseCurrency.code;
    final loaded = ref.watch(activityAccountsProvider);
    final lineAccounts = ref.watch(readLineAccountsProvider);
    final hidden = ref.watch(hiddenLineAccountsProvider);
    final lines = ref.watch(mpesaLinesProvider).value ?? MpesaLines.empty;
    final readsMpesa = ref.watch(readsMpesaHereProvider).value ?? false;
    // M-Pesa with linked accounts is a group of its own (decision 0026).
    final families = <MpesaFamily>[
      for (final f
          in ref.watch(mpesaFamiliesProvider).value ?? const <MpesaFamily>[])
        if (f.hasMembers && !hidden.contains(f.wallet.account.id)) f,
    ];
    final grouped = {
      for (final f in families) ...[
        f.wallet.account.id,
        for (final b in f.business) b.account.id,
      ],
    };
    final named = withLineNames({...?loaded.value}, lineAccounts);
    // Savings apps, such as Chumz, have a card of their own. A line given
    // to another space leaves an empty account here, not shown.
    final accounts = [
      for (final a in named.values)
        if (a.product == null &&
            !hidden.contains(a.id) &&
            !grouped.contains(a.id))
          a,
    ]..sort((a, b) => a.id.compareTo(b.id));
    final institutions = {
      for (final i in ref.watch(institutionCatalogueProvider)) i.id: i,
    };

    return Scaffold(
      appBar: AppBar(
        title: Semantics(
          identifier: SemanticIds.titleProfileMyAccounts,
          child: const Text('My accounts'),
        ),
      ),
      body: !loaded.hasValue
          ? loaded.hasError
                ? ErrorView(
                    'Your accounts could not load.',
                    onRetry: () => ref.invalidate(activityAccountsProvider),
                  )
                : const LoadingView()
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                if (families.isNotEmpty) ...[
                  OwnAndOweCard(families: families),
                  const SizedBox(height: 16),
                ],
                Text(
                  'Each amount keeps the currency its message shows. Totals add '
                  'them up in your base currency, $base.',
                  style: theme.textTheme.bodyLarge!.copyWith(
                    color: colors.textMuted,
                  ),
                ),
                if (readsMpesa && lines.offersSplit && !lines.offerHidden) ...[
                  const SizedBox(height: 16),
                  const _SplitOffer(),
                ],
                for (final f in families) ...[
                  const SizedBox(height: 16),
                  MpesaFamilyCard(
                    family: f,
                    name: named[f.wallet.account.id]?.name ?? 'M-Pesa',
                  ),
                ],
                if (accounts.isNotEmpty) ...[
                  SizedBox(height: families.isEmpty ? 16 : Layout.cardGap),
                  Card(
                    child: Column(
                      children: [
                        for (final (i, account) in accounts.indexed) ...[
                          if (i > 0) const Divider(height: 1),
                          _AccountRow(
                            account: account,
                            from: _fromLine(
                              context,
                              account,
                              institutions,
                              lineAccounts[account.id],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                const SavingsAccountsCard(),
                const SizedBox(height: 12),
                Notice(
                  [
                    'Accounts at the same bank are told apart by the account '
                        'number in their messages.',
                    if (lines.split)
                      lines.bySim
                          ? 'M-Pesa lines are told apart by the SIM their '
                                'messages arrive on.'
                          : 'M-Pesa lines are told apart by the balance each '
                                'message shows.',
                    'Each counts in the currency its messages show.',
                  ].join(' '),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      if (lines.twoSeen) ...[
                        _LinesRow(lines: lines),
                        const Divider(height: 1),
                      ],
                      Semantics(
                        identifier: SemanticIds.myAccountsChoose,
                        child: ListTile(
                          key: const Key('choose-accounts'),
                          title: const Text('Add or remove accounts'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => context.push(AppRoutes.chooseAccounts),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// `Account 0170…4321` once its messages show a number, `Messages from
/// MPESA` before, or `Money you add by hand` for an account no messages
/// feed. An M-Pesa line says how it is told apart: `Messages from MPESA ·
/// SIM 1`, or by its balance where the phone reports no SIM.
String _fromLine(
  BuildContext context,
  Account account,
  Map<String, Institution> institutions,
  MpesaLine? line,
) {
  final institution = institutions[account.institutionId];
  if (account.institutionId == null) return 'Money you add by hand';
  final number = AccountReference.tryParse(account.reference);
  if (number != null) return 'Account ${number.label}';
  if (institution == null) return account.name;
  final senders = institution.senderIds;
  final from =
      'Messages from ${senders.isEmpty ? institution.name : senders.join(', ')}';
  if (line == null) return from;
  if (line.sims.isNotEmpty) return '$from · ${line.slot}';
  final balance = line.balanceMinor;
  return balance == null
      ? from
      : '$from · balance ${shownMoney(context, balance, withCurrency: false)}';
}

/// "Two M-Pesa lines on this phone": what is wrong, Split them, and Not
/// now. Nothing is split without asking.
class _SplitOffer extends ConsumerWidget {
  const _SplitOffer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    return Card(
      key: const Key('lines-offer'),
      child: Padding(
        padding: const EdgeInsets.all(Layout.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Two M-Pesa lines on this phone',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Both are read into one M-Pesa account, so their payments are '
              'mixed and the balance jumps between the two.',
              style: theme.textTheme.bodyMedium!.copyWith(
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: 12),
            ButtonPair(
              primary: FilledButton(
                key: const Key('lines-offer-split'),
                onPressed: () => showMpesaLinesSheet(context),
                child: const Text('Split them'),
              ),
              secondary: OutlinedButton(
                key: const Key('lines-offer-later'),
                onPressed: () =>
                    ref.read(mpesaLinesProvider.notifier).hideOffer(),
                child: const Text('Not now'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "M-Pesa lines", once two lines have been seen: where a line given to
/// another space is, and the way to name and move them.
class _LinesRow extends ConsumerWidget {
  const _LinesRow({required this.lines});

  final MpesaLines lines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spaces = ref.watch(spacesProvider).value ?? const [Space.personal];
    final names = {for (final s in spaces) s.id: s.name};
    final here = ref.watch(activeSpaceIdProvider);
    final listed = names.keys.toSet();
    final elsewhere = [
      if (lines.split)
        for (final line in lines.lines)
          if (lines.readerOf(line, listed) case final reader
              when reader != here)
            '${line.label} is in ${names[reader] ?? 'Personal'}',
    ];
    return ListTile(
      key: const Key('mpesa-lines'),
      title: const Text('M-Pesa lines'),
      subtitle: Text(
        elsewhere.isEmpty
            ? 'Name them, or give one to a business'
            : elsewhere.join('. '),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showMpesaLinesSheet(context),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.account, required this.from});

  final Account account;
  final String from;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = PesaColors.of(context);
    final name = currencyCatalogue[account.currency]?.name ?? account.currency;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(account.name, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  from,
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (account.institutionId != null)
            // Its messages say which currency it is in.
            Semantics(
              label: '${account.name} counts in $name, from its messages',
              excludeSemantics: true,
              child: Tag(
                account.currency,
                key: Key('account-currency-${account.id}'),
              ),
            )
          else
            Semantics(
              button: true,
              label: '${account.name} currency: $name. Change',
              excludeSemantics: true,
              child: OutlinedButton(
                key: Key('account-currency-${account.id}'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AccountCurrencyScreen(accountId: account.id),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(account.currency, style: theme.textTheme.labelLarge),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 20,
                      color: colors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
