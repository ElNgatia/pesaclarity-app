import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../domain/accounts/mpesa_family.dart';
import '../../../domain/enums.dart';
import '../../../domain/savings/savings_account.dart';
import '../../../domain/time/calendar.dart';
import '../../balances/application/balances_providers.dart';
import '../../savings/application/savings_providers.dart';

/// One M-Pesa wallet and the accounts linked to it (decision 0026), as My
/// accounts shows them.
class MpesaFamily {
  const MpesaFamily({
    required this.wallet,
    this.saved = const [],
    this.invested = const [],
    this.business = const [],
  });

  /// The wallet at the family's head; its Fuliza owed is its owed member.
  final AccountBalance wallet;

  /// Savings members, such as M-Shwari.
  final List<SavingsAccountSummary> saved;

  /// Invested members, such as Ziidi.
  final List<SavingsAccountSummary> invested;

  /// The person's own Pochi la Biashara: business money, so it is not
  /// added to what the family holds.
  final List<AccountBalance> business;

  String get currency => wallet.opening.currency;

  int get walletMinor => wallet.walletMinor;
  int get fulizaOwedMinor => wallet.fulizaOwedMinor;
  int get savedMinor => saved.fold(0, (sum, s) => sum + s.balanceMinor);
  int get investedMinor => invested.fold(0, (sum, s) => sum + s.balanceMinor);

  /// What the family holds of the person's own: the wallet, savings and
  /// investments.
  int get ownMinor => walletMinor + savedMinor + investedMinor;

  /// What it owes: Fuliza.
  int get owedMinor => fulizaOwedMinor;

  /// What is the person's after debts.
  int get afterDebtsMinor => ownMinor - owedMinor;

  int get businessMinor => business.fold(0, (sum, b) => sum + b.heldMinor);

  /// How many accounts are linked to the wallet: each member, and Fuliza
  /// while it is owed.
  int get linkedCount =>
      saved.length +
      invested.length +
      business.length +
      (fulizaOwedMinor > 0 ? 1 : 0);

  /// Whether it has linked accounts, so My accounts shows it as a group.
  bool get hasMembers =>
      saved.isNotEmpty || invested.isNotEmpty || business.isNotEmpty;
}

/// What [account] earned in [month]'s calendar month: the interest or
/// returns its balances showed.
int earnedIn(SavingsAccountSummary account, CalendarDate month) => account
    .updates
    .where((u) {
      final day = CalendarDate.local(u.at);
      return day.year == month.year && day.month == month.month;
    })
    .fold(0, (sum, u) => sum + u.interestMinor);

/// The M-Pesa families of the open space, one per wallet, in the wallets'
/// order. A member that names no wallet joins the first.
final mpesaFamiliesProvider = FutureProvider<List<MpesaFamily>>((ref) async {
  final overview = await ref.watch(balancesOverviewProvider.future);
  final savings = await ref.watch(savingsAccountsProvider.future);
  final accounts = {for (final b in overview.accounts) b.account.id: b};
  final wallets = [
    for (final b in overview.accounts)
      if (b.account.type == AccountType.mpesa) b,
  ]..sort((a, b) => a.account.id.compareTo(b.account.id));
  if (wallets.isEmpty) return const [];
  int walletOf(int? familyOf) => wallets.any((w) => w.account.id == familyOf)
      ? familyOf!
      : wallets.first.account.id;
  return [
    for (final w in wallets)
      MpesaFamily(
        wallet: w,
        saved: [
          for (final s in savings)
            if (s.product case final p? when p.inMpesaFamily && !p.invested)
              if (walletOf(accounts[s.accountId]?.account.familyOf) ==
                  w.account.id)
                s,
        ],
        invested: [
          for (final s in savings)
            if (s.product case final p? when p.inMpesaFamily && p.invested)
              if (walletOf(accounts[s.accountId]?.account.familyOf) ==
                  w.account.id)
                s,
        ],
        business: [
          for (final b in overview.accounts)
            if (isPochiReference(b.account.reference) &&
                walletOf(b.account.familyOf) == w.account.id)
              b,
        ],
      ),
  ];
});

/// The month "returns this month" counts, from the app's clock.
final familyMonthProvider = Provider<CalendarDate>(
  (ref) => CalendarDate.local(ref.watch(clockProvider)()),
);
