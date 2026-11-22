import '../books/journal_balances.dart';
import '../time/calendar.dart';
import 'balances.dart';
import 'ledger_entry.dart';

/// Day-to-day money at the start of a day: each day-to-day account's real
/// worth (Fuliza owed taken off), less the rainy day fund and what is set
/// aside for goals. Savings accounts (SACCO, money market) are not counted.
class OnHand {
  const OnHand({
    required this.byAccount,
    required this.rainyDayMinor,
    required this.fulizaOwedMinor,
    this.goalsWantedMinor = 0,
  });

  /// What day-to-day [accounts] held at the start of [today], from the
  /// journal's [balances]. A balance set by hand today (in [entries])
  /// counts from the start of the day, so Home follows the figure the
  /// person just typed. [goalsKeptMinor] is what the goals kept aside
  /// hold (see `GoalsAside`).
  factory OnHand.at(
    Iterable<AccountOpening> accounts,
    Iterable<LedgerEntry> entries, {
    required JournalBalances balances,
    required CalendarDate today,
    required int rainyDayMinor,
    int goalsKeptMinor = 0,
  }) {
    final list = entries.toList();
    final start = today.startInstant;
    final byAccount = <int, int>{};
    var owed = 0;
    for (final account in accounts) {
      if (account.isSavings) continue;
      final setToday = list
          .where(
            (e) =>
                e.accountId == account.id &&
                e.currency == account.currency &&
                e.isCorrection &&
                e.date == today,
          )
          .fold(0, (sum, e) => sum + e.signedMinor);
      byAccount[account.id] = balances.heldAt(account, at: start) + setToday;
      owed += balances.fulizaOwedAt(account, at: today.addDays(1).startInstant);
    }
    return OnHand(
      byAccount: byAccount,
      rainyDayMinor: rainyDayMinor,
      fulizaOwedMinor: owed,
      goalsWantedMinor: goalsKeptMinor,
    );
  }

  /// Each day-to-day account's worth, by account id.
  final Map<int, int> byAccount;

  /// Money in the rainy day fund: still in the accounts, not for spending.
  final int rainyDayMinor;

  /// Fuliza owed now, already taken off its account in [byAccount].
  final int fulizaOwedMinor;

  /// What the goals kept aside hold while nothing has dipped into them.
  final int goalsWantedMinor;

  int get accountsMinor => byAccount.values.fold(0, (sum, v) => sum + v);

  /// The accounts less the rainy day fund, before goals are set aside.
  int get beforeGoalsMinor => accountsMinor - rainyDayMinor;

  /// What is set aside for goals: all they hold, or, once spending has
  /// gone past the free money, as much as is left. Never below zero.
  int get goalsAsideMinor {
    final before = beforeGoalsMinor;
    if (before <= 0 || goalsWantedMinor <= 0) return 0;
    return before < goalsWantedMinor ? before : goalsWantedMinor;
  }

  /// How much spending has dipped into the goals kept aside.
  int get goalsDippedMinor => goalsWantedMinor - goalsAsideMinor;

  /// On hand: the accounts less the rainy day fund and what is set aside
  /// for goals. Zero, not below, when spending has only dipped into the
  /// goals; below zero when Fuliza or an overdraft is more than the money.
  int get totalMinor => beforeGoalsMinor - goalsAsideMinor;
}
