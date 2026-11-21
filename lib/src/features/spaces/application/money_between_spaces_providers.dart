import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/database/app_database.dart';
import '../../../data/database/database_providers.dart';
import '../../../data/repositories/balance_records_repository.dart';
import '../../../data/repositories/journal_repository.dart';
import '../../../data/repositories/transactions_repository.dart';
import '../../../domain/books/journal_balances.dart';
import '../../../domain/spaces/money_between_spaces.dart';
import '../../../domain/spaces/space.dart';
import '../../activity/application/activity_providers.dart';
import 'spaces_providers.dart';

/// The open space's money between spaces (decision 0027), from its
/// journal: what its own accounts hold for other spaces, and what it has
/// on other spaces' accounts.
final moneyBetweenSpacesProvider = FutureProvider<MoneyBetweenSpaces>((
  ref,
) async {
  ref.watch(ledgerChangesProvider);
  final accounts = await betweenSpacesAccounts(ref.watch(appDatabaseProvider));
  if (accounts.isEmpty) {
    return MoneyBetweenSpaces.of(const [], JournalBalances(const []));
  }
  return MoneyBetweenSpaces.of(accounts, await readJournal(ref));
});

/// The part of the open space's own accounts that is another space's just
/// before [at], which safe to spend and the forecast leave out (owner's
/// decision 3). Nothing when it holds nothing for another space.
Future<int> notOwnMinorAt(Ref ref, DateTime at) async {
  final accounts = await betweenSpacesAccounts(ref.read(appDatabaseProvider));
  if (accounts.isEmpty) return 0;
  return MoneyBetweenSpaces.of(
    accounts,
    await readJournal(ref),
    at: at,
  ).notOwnMinor;
}

/// Space names by id, for the lines that say whose money it is. A space
/// deleted while its money was kept apart (owner's decision 9) keeps the
/// name its accounts here were given.
final spaceNamesProvider = Provider<Map<String, String>>((ref) {
  final spaces = ref.watch(spacesProvider).value ?? const <Space>[];
  final accounts = ref.watch(activityAccountsProvider).value ?? const {};
  const heldFor = 'Held for ';
  return {
    for (final a in accounts.values)
      if (a.linkedSpaceId case final id?
          when a.type == AccountType.heldForSpace && a.name.startsWith(heldFor))
        id: a.name.substring(heldFor.length)
      else if (a.linkedSpaceId case final id?
          when a.type == AccountType.paidBySpace)
        id: a.name,
    for (final s in spaces) s.id: s.name,
  };
});

/// The line under an amount that says how much of it is another space's:
/// "KES 650 of this is Vegetable stall's", or "Vegetable stall owes you KES
/// 350". Null when nothing on it is.
String? heldLine(
  Map<String, int> heldBySpace,
  Map<String, String> names,
  String Function(int minor) money,
) {
  if (heldBySpace.isEmpty) return null;
  final lines = [
    for (final MapEntry(key: space, value: minor) in heldBySpace.entries)
      minor > 0
          ? "${money(minor)} of this is ${names[space] ?? 'another space'}'s"
          : '${names[space] ?? 'Another space'} owes you ${money(-minor)}',
  ];
  return lines.join('. ');
}
