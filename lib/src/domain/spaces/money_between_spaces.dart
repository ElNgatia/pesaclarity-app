import '../books/book_account.dart';
import '../books/journal_balances.dart';
import '../enums.dart';

/// An account kept for money between spaces (decision 0027), as the
/// figures need it.
class BetweenSpacesAccount {
  const BetweenSpacesAccount({
    required this.id,
    required this.type,
    required this.spaceId,
    required this.currency,
    this.accountId,
  }) : assert(
         type == AccountType.heldForSpace ||
             type == AccountType.ownersAccount ||
             type == AccountType.paidBySpace,
         'only accounts kept for money between spaces',
       );

  final int id;
  final AccountType type;

  /// The other space.
  final String spaceId;

  /// The real account the money is on, by its id where it lives: in the
  /// space itself for Held for, in [spaceId] for the owner's account.
  final int? accountId;
  final String currency;

  BookAccount get bookAccount => BookAccount.forAccount(id, type);
}

/// How much of the space's own accounts belongs to other spaces, and how
/// much of its money is on other spaces' accounts: the figures under On
/// hand, under each account in Balances, and on the business's Money.
class MoneyBetweenSpaces {
  MoneyBetweenSpaces._(this._held, this._owners);

  /// Reads [accounts] from the journal's [balances] just before [at] (or
  /// after every posting).
  factory MoneyBetweenSpaces.of(
    Iterable<BetweenSpacesAccount> accounts,
    JournalBalances balances, {
    DateTime? at,
  }) {
    final held = <BetweenSpacesAccount, int>{};
    final owners = <BetweenSpacesAccount, int>{};
    for (final a in accounts) {
      final minor = balances.balanceOf(
        a.bookAccount,
        currency: a.currency,
        at: at,
      );
      switch (a.type) {
        case AccountType.heldForSpace:
          held[a] = minor;
        case AccountType.ownersAccount:
          owners[a] = minor;
        case _:
          break;
      }
    }
    return MoneyBetweenSpaces._(held, owners);
  }

  final Map<BetweenSpacesAccount, int> _held;
  final Map<BetweenSpacesAccount, int> _owners;

  /// What this space holds for [spaceId] on its accounts, or with
  /// [accountId] on that one account. Below zero, [spaceId] owes this
  /// space.
  int heldFor(String spaceId, {int? accountId}) => _held.entries
      .where(
        (e) =>
            e.key.spaceId == spaceId &&
            (accountId == null || e.key.accountId == accountId),
      )
      .fold(0, (sum, e) => sum + e.value);

  /// What this space holds for any other space on [accountId], by space,
  /// zeros left out.
  Map<String, int> heldOn(int accountId) {
    final out = <String, int>{};
    for (final MapEntry(key: a, :value) in _held.entries) {
      if (a.accountId != accountId) continue;
      out[a.spaceId] = (out[a.spaceId] ?? 0) + value;
    }
    return out..removeWhere((_, v) => v == 0);
  }

  /// What this space holds for other spaces, by space, zeros left out.
  Map<String, int> get heldBySpace {
    final out = <String, int>{};
    for (final MapEntry(key: a, :value) in _held.entries) {
      out[a.spaceId] = (out[a.spaceId] ?? 0) + value;
    }
    return out..removeWhere((_, v) => v == 0);
  }

  /// The part of the space's own accounts that is not its own: what it
  /// holds for other spaces, where that is above zero. Safe to spend leaves
  /// it out. What another space owes this one is not added to what can be
  /// spent.
  int get notOwnMinor =>
      heldBySpace.values.where((v) => v > 0).fold(0, (sum, v) => sum + v);

  /// The space's money on accounts that live in other spaces, by owner's
  /// account. Below zero on one, it is what the owner has put in.
  Map<BetweenSpacesAccount, int> get onOwnersAccounts =>
      Map.unmodifiable(_owners);

  /// The space's money on [spaceId]'s accounts, all of them together.
  int onAccountsOf(String spaceId) => _owners.entries
      .where((e) => e.key.spaceId == spaceId)
      .fold(0, (sum, e) => sum + e.value);

  /// What the space has on its owner's accounts and counts as money: each
  /// owner's account above zero. Money the owner has put in is shown and
  /// not counted (owner's decision 4).
  int get ownersMoneyMinor =>
      _owners.values.where((v) => v > 0).fold(0, (sum, v) => sum + v);

  /// What the owner has put in: the owner's accounts below zero, as a
  /// positive amount.
  int get putInMinor =>
      -_owners.values.where((v) => v < 0).fold(0, (sum, v) => sum + v);

  /// What the space has on its owner's account [id]: the most Pay yourself
  /// can take from that line (owner's decision 5), never below zero.
  int payableFrom(int id) {
    for (final MapEntry(key: a, :value) in _owners.entries) {
      if (a.id == id) return value < 0 ? 0 : value;
    }
    return 0;
  }
}

/// Why Pay yourself on a shared line cannot take [amountMinor] (owner's
/// decision 5): no more than the business has on that line. Null when it
/// can.
String? payYourselfLimitError({
  required int amountMinor,
  required int onLineMinor,
  required String business,
  required String line,
  required String Function(int minor) money,
}) {
  if (amountMinor <= onLineMinor) return null;
  return 'The ${shortSpaceName(business)} has ${money(onLineMinor)} on your '
      '$line. To take more, pay from another business account.';
}

/// A short way to name a space in a sentence: "the stall" for "Vegetable
/// stall" reads as the mockups do, but a space's own name is clearer for
/// any name, so the name is used as it is, lower-cased only in its first
/// letter when it is more than one word.
String shortSpaceName(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  if (words.length < 2) return name.trim();
  return words.last.toLowerCase();
}
