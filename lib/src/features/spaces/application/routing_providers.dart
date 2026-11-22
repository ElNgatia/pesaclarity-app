import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/database/app_database.dart';
import '../../../data/database/database_providers.dart';
import '../../../data/database/space_databases.dart';
import '../../../data/repositories/app_settings_repository.dart';
import '../../../data/repositories/institutions_repository.dart';
import '../../../data/repositories/space_move_repository.dart';
import '../../../domain/accounts/mpesa_family.dart';
import '../../../domain/accounts/mpesa_lines.dart';
import '../../../domain/spaces/kept_data.dart';
import '../../../domain/spaces/line_routing.dart';
import '../../../domain/spaces/space.dart';
import 'space_manager.dart';
import 'spaces_providers.dart';

/// How far back the business asks about payments on a shared line.
const sharedLineLookback = Duration(days: 30);

/// Most "kept in Personal" answers remembered, newest kept.
const keptPersonalLimit = 2000;

/// The line rules, in Personal's settings.
class RoutingRulesController extends AsyncNotifier<RoutingRules> {
  static const settingsKey = routingRulesKey;

  AppSettingsRepository get _settings =>
      ref.read(mainSettingsRepositoryProvider);

  @override
  Future<RoutingRules> build() async => _withoutGoneSpaces(
    RoutingRules.fromJson(await _settings.readJson(settingsKey)),
  );

  /// Rules never outlive their space. [saved] may still hold some for a
  /// space deleted before its rules went with it: they join that space's
  /// kept copy when there is one, so a restore puts them back, and are
  /// dropped otherwise.
  Future<RoutingRules> _withoutGoneSpaces(RoutingRules saved) async {
    final listed = {
      for (final space in await ref.read(spacesProvider.future)) space.id,
    };
    final rules = saved.onlyFor(listed);
    if (rules.sharedLines.length == saved.sharedLines.length &&
        rules.people.length == saved.people.length) {
      return saved;
    }
    final kept = await ref.read(keptDataProvider.future);
    final withRules = [
      for (final k in kept)
        k.kind == KeptKind.space &&
                k.rules == null &&
                !listed.contains(k.space.id) &&
                !saved.forSpace(k.space.id).isEmpty
            ? k.withRules(saved.forSpace(k.space.id))
            : k,
    ];
    if (withRules.any((k) => !kept.contains(k))) {
      await ref.read(keptDataProvider.notifier).save(withRules);
    }
    await _settings.writeJson(settingsKey, rules.toJson());
    return rules;
  }

  Future<RoutingRules> _current() async => state.value ?? await future;

  Future<void> _save(RoutingRules next) async {
    await _settings.writeJson(settingsKey, next.toJson());
    state = AsyncData(next);
  }

  /// Sets where [institutionId] is read, for the business [businessId].
  ///
  /// [LineChoice.both] keeps the line in Personal only, so each message is
  /// read once, and the business asks about its payments.
  Future<void> setLine(
    String institutionId,
    LineChoice choice, {
    required String businessId,
    required InstitutionsRepository business,
    required InstitutionsRepository personal,
  }) async {
    final current = await _current();
    // Off where it goes off first: an account is read in one space, so it
    // cannot be switched on in the other while this one still reads it.
    if (choice == LineChoice.thisBusiness) {
      await personal.setSelected(institutionId, selected: false);
      await business.setSelected(institutionId, selected: true);
      if (!(await business.selectedIds()).contains(institutionId)) {
        // Another business reads it: it stays with Personal.
        await personal.setSelected(institutionId, selected: true);
        return;
      }
    } else {
      await business.setSelected(institutionId, selected: false);
      await personal.setSelected(institutionId, selected: true);
    }
    await _save(
      choice == LineChoice.both
          ? current.withNewShare(institutionId, businessId)
          : current.withLine(institutionId, null),
    );
  }

  /// Leaves to Personal each account [space] has switched on while Personal
  /// reads it too, so no message is read into both: a business shares it
  /// with Personal, as Business or personal already showed it ("Used for
  /// both"), unless another business shares it already; any other space
  /// just stops reading it. Returns whether anything changed.
  ///
  /// A second space could switch on an account Personal read before each
  /// account was kept to one space, and a restored copy can bring such a
  /// choice back.
  Future<bool> readOnce(
    Space space, {
    required InstitutionsRepository here,
    required InstitutionsRepository personal,
  }) async {
    if (space.id == personalSpaceId) return false;
    final both = (await here.selectedIds()).intersection(
      await personal.selectedIds(),
    );
    if (both.isEmpty) return false;
    final current = await _current();
    final next = current.readOnce(
      both,
      spaceId: space.id,
      business: space.kind == SpaceKind.business,
    );
    for (final line in both) {
      await here.setSelected(line, selected: false);
    }
    await _save(next);
    return true;
  }

  /// Shares [line] (an institution, or one M-Pesa line by its
  /// `lineSelectionId`) with [businessId], or stops sharing it with null.
  Future<void> shareLine(String line, String? businessId) async {
    final current = await _current();
    if (current.sharedLines[line] == businessId) return;
    await _save(current.withLine(line, businessId));
  }

  /// Sets the business's own channels on [line] (decision 0027, section 4).
  Future<void> setChannels(String line, LineChannels channels) async =>
      _save((await _current()).withChannels(line, channels));

  /// Remembers that money from [key] goes to [spaceId].
  Future<void> rememberPerson(String key, String spaceId) async =>
      _save((await _current()).withPerson(key, spaceId));

  /// Takes the rules that send money to [spaceId] out of use, as it is
  /// deleted.
  Future<void> forgetSpace(String spaceId) async =>
      _save((await _current()).withoutSpace(spaceId));

  /// Puts back the rules [older] of a deleted space that is restored. What
  /// was chosen since stays.
  Future<void> putBack(RoutingRules? older) async {
    if (older == null || older.isEmpty) return;
    await _save((await _current()).withPutBack(older));
  }
}

final routingRulesProvider =
    AsyncNotifierProvider<RoutingRulesController, RoutingRules>(
      RoutingRulesController.new,
    );

/// A payment on a shared line, waiting for "Was this for the business?".
class SharedLineQuestion {
  const SharedLineQuestion({
    required this.transactionId,
    required this.institutionId,
    required this.amountMinor,
    required this.currency,
    required this.isInflow,
    required this.at,
    this.name,
    this.personKey,
    this.onOwnAccount = false,
    this.through = const ReceivedThrough(ChannelKind.unclear),
    this.asksNumber = false,
    String? line,
  }) : line = line ?? institutionId;

  /// The shared line it is on, as the rules key it: [institutionId], or an
  /// M-Pesa line's `lineSelectionId` once lines are told apart. Its
  /// channels are this line's.
  final String line;

  /// The channel it came in through (decision 0027, section 4).
  final ReceivedThrough through;

  /// "Is till 123456 Vegetable stall's?", asked once for a till or paybill
  /// the app has not seen.
  final bool asksNumber;

  SharedLineQuestion asNumber() => SharedLineQuestion(
    transactionId: transactionId,
    institutionId: institutionId,
    amountMinor: amountMinor,
    currency: currency,
    isInflow: isInflow,
    at: at,
    name: name,
    personKey: personKey,
    through: through,
    asksNumber: true,
    line: line,
  );

  /// The transaction's id: in Personal, or for a payment on the business's
  /// own account ([onOwnAccount]), in the business.
  final int transactionId;

  /// A payment out of one of the business's own accounts whose meaning is
  /// unclear (decision 0027, section 6): "Business cost" or "This was for
  /// me".
  final bool onOwnAccount;
  final String institutionId;
  final int amountMinor;
  final String currency;
  final bool isInflow;
  final DateTime at;

  /// The other party's name as the message gave it.
  final String? name;
  final String? personKey;
}

/// Sorts money on shared lines between Personal and a business: it lists
/// what to ask about, applies what the owner taught it, and moves answered
/// payments.
class SharedLineRouter {
  SharedLineRouter({
    required AppDatabase personal,
    required SpaceMoveRepository moveFromPersonal,
    required this.rules,
    required this.remember,
    required this.now,
    this.saveChannels,
  }) : _personal = personal,
       _move = moveFromPersonal,
       _kept = DriftAppSettingsRepository(personal);

  static const keptKey = 'routing.keptPersonal';

  final AppDatabase _personal;
  final SpaceMoveRepository _move;

  /// Reads the current rules.
  final Future<RoutingRules> Function() rules;

  /// Saves that money from a person goes to a space.
  final Future<void> Function(String key, String spaceId) remember;

  /// Saves the business's own channels on a line.
  final Future<void> Function(String line, LineChannels channels)? saveChannels;
  final DateTime Function() now;
  final AppSettingsRepository _kept;

  Future<List<int>> _keptIds() async {
    final raw = (await _kept.readJson(keptKey))?['ids'];
    return [
      if (raw is List)
        for (final id in raw)
          if (id is int) id,
    ];
  }

  Future<void> _keep(int transactionId) async {
    final ids = [...await _keptIds(), transactionId];
    final trimmed = ids.length > keptPersonalLimit
        ? ids.sublist(ids.length - keptPersonalLimit)
        : ids;
    await _kept.writeJson(keptKey, {'ids': trimmed});
  }

  /// Recent payments in Personal on any line shared with a business, newest
  /// first, that are not own transfers and not yet kept in Personal.
  Future<List<(SharedLineQuestion, String)>> _recent(RoutingRules rules) async {
    if (rules.sharedLines.isEmpty) return const [];
    final t = _personal.transactions;
    final a = _personal.accounts;
    final since = now().subtract(sharedLineLookback);
    // A shared M-Pesa line is its own account.
    final lines = [
      for (final key in rules.sharedLines.keys)
        if (lineOfSelection(key) case final id?) lineReference(id),
    ];
    // The owner's Pochi la Biashara goes with any shared M-Pesa line: its
    // money decides by its channel (decision 0027, section 4).
    final mpesaShared = [
      for (final key in rules.sharedLines.keys)
        if (key == mpesaInstitutionId || lineOfSelection(key) != null) key,
    ];
    final shared =
        a.institutionId.isIn(rules.sharedLines.keys) |
        (a.institutionId.equals(mpesaInstitutionId) & a.reference.isIn(lines)) |
        (a.institutionId.equals(mpesaInstitutionId) &
            a.reference.equals(pochiReference) &
            Constant(mpesaShared.isNotEmpty));
    final rows =
        await (_personal.select(t).join([
                innerJoin(a, a.id.equalsExp(t.accountId)),
              ])
              ..where(
                shared &
                    t.occurredAt.isBiggerOrEqualValue(since) &
                    t.transferPairId.isNull(),
              )
              ..orderBy([OrderingTerm.desc(t.occurredAt)]))
            .get();
    String? ruleOf(Account account) {
      if (isPochiReference(account.reference)) {
        return rules.sharedLines.containsKey(mpesaInstitutionId)
            ? mpesaInstitutionId
            : mpesaShared.firstOrNull;
      }
      final line = lineOfReference(account.reference);
      final key = line == null ? null : lineSelectionId(line);
      return rules.sharedLines.containsKey(key)
          ? key
          : rules.sharedLines.containsKey(account.institutionId)
          ? account.institutionId
          : null;
    }

    final kept = (await _keptIds()).toSet();
    return [
      for (final row in rows)
        if (row.readTable(t) case final tx when !kept.contains(tx.id))
          if (ruleOf(row.readTable(a)) case final rule?)
            (
              SharedLineQuestion(
                transactionId: tx.id,
                institutionId: row.readTable(a).institutionId!,
                amountMinor: tx.amountMinor,
                currency: tx.currency,
                isInflow: tx.direction.name == 'inflow',
                at: tx.occurredAt,
                name: tx.counterpartyName,
                personKey: personKey(
                  kind: tx.counterpartyKind,
                  value: tx.counterpartyValue,
                  name: tx.counterpartyName,
                ),
                line: rule,
                through: receivedThrough(
                  isInflow: tx.direction.name == 'inflow',
                  kind: tx.kind ?? TransactionKind.bank,
                  counterpartyKind: tx.counterpartyKind,
                  // Money into the owner's own Pochi (decision 0026).
                  channel:
                      isPochiReference(row.readTable(a).reference) &&
                          tx.direction.name == 'inflow'
                      ? const ReceivedThrough(ChannelKind.ownPochi)
                      : null,
                ),
              ),
              rules.sharedLines[rule]!,
            ),
    ];
  }

  /// Moves or keeps every recent payment whose person the owner already
  /// taught the app about. Returns how many it sorted.
  Future<int> applyRules() async {
    final current = await rules();
    var sorted = 0;
    for (final (q, business) in await _recent(current)) {
      // The channel decides first (decision 0027, section 4).
      final route = current.routeOf(q.line, q.through);
      if (route.spaceId case final to?) {
        if (to == personalSpaceId) {
          await _keep(q.transactionId);
        } else {
          await _move.move(q.transactionId, to);
        }
        sorted++;
        continue;
      }
      if (route.asksNumber) continue;
      final target = q.personKey == null ? null : current.people[q.personKey];
      if (target == null) continue;
      if (target == personalSpaceId) {
        await _keep(q.transactionId);
      } else if (target == business) {
        await _move.move(q.transactionId, business);
      } else {
        continue;
      }
      sorted++;
    }
    return sorted;
  }

  /// What [businessId] still has to ask about, after applying the rules.
  Future<List<SharedLineQuestion>> pending(String businessId) async {
    await applyRules();
    final current = await rules();
    return [
      for (final (q, business) in await _recent(current))
        if (business == businessId)
          if (current.routeOf(q.line, q.through).asksNumber)
            q.asNumber()
          else if (q.personKey == null ||
              !current.people.containsKey(q.personKey))
            q,
    ];
  }

  /// Answers "Is till 123456 Vegetable stall's?": "Yes" names the till as
  /// [businessId]'s and sends this payment, and later ones through it,
  /// there; "No" asks no more about the till, and the payment is asked
  /// about as before (approved screens, choice 4).
  Future<void> answerNumber(
    SharedLineQuestion question, {
    required String businessId,
    required bool ours,
  }) async {
    final kind = question.through.kind;
    final number = question.through.number;
    if (number == null) return;
    final line = (await rules()).channelsOn(question.line);
    await saveChannels?.call(
      question.line,
      ours
          ? line.withNumber(kind, number, businessId)
          : line.withNotOurs(kind, number),
    );
    if (ours) await _move.move(question.transactionId, businessId);
  }

  /// Answers [question]: moves it to [businessId] or keeps it in Personal,
  /// and with [always] remembers the choice for its person.
  Future<void> answer(
    SharedLineQuestion question, {
    required String businessId,
    required bool forBusiness,
    required bool always,
  }) async {
    if (forBusiness) {
      await _move.move(question.transactionId, businessId);
    } else {
      await _keep(question.transactionId);
    }
    final key = question.personKey;
    if (always && key != null) {
      await remember(key, forBusiness ? businessId : personalSpaceId);
    }
  }
}

/// The router, moving out of Personal into whichever business is asked.
final sharedLineRouterProvider = Provider<SharedLineRouter>((ref) {
  final personal = ref.watch(personalDatabaseProvider);
  final spaces = ref.watch(spaceDatabasesProvider);
  final mover = DriftSpaceMoveRepository(
    personal,
    // Only a business still on the list: see [SpaceDatabases.open].
    spaces.open,
    nameOf: spaces.nameOf,
  );
  return SharedLineRouter(
    personal: personal,
    moveFromPersonal: mover,
    rules: () => ref.read(routingRulesProvider.future),
    remember: (key, spaceId) =>
        ref.read(routingRulesProvider.notifier).rememberPerson(key, spaceId),
    saveChannels: (line, channels) =>
        ref.read(routingRulesProvider.notifier).setChannels(line, channels),
    now: ref.watch(clockProvider),
  );
});

/// Asks about payments out of a business's own accounts that may have been
/// the owner's (decision 0027, section 6; approved screens, choice 3): only
/// when it is unclear, that is when nothing has filed them yet. What the
/// owner taught it about a person applies by itself.
class OwnAccountAsker {
  OwnAccountAsker({
    required AppDatabase business,
    required this.businessId,
    required this.moves,
    required this.rules,
    required this.remember,
    required this.now,
  }) : _db = business,
       _kept = DriftAppSettingsRepository(business);

  static const keptKey = 'routing.keptBusiness';

  final AppDatabase _db;
  final String businessId;

  /// Makes "This was for me".
  final SpaceMoveRepository moves;
  final Future<RoutingRules> Function() rules;
  final Future<void> Function(String key, String spaceId) remember;
  final DateTime Function() now;
  final AppSettingsRepository _kept;

  Future<Set<int>> _keptIds() async {
    final raw = (await _kept.readJson(keptKey))?['ids'];
    return {
      if (raw is List)
        for (final id in raw)
          if (id is int) id,
    };
  }

  Future<void> _keep(int id) async {
    final ids = [...await _keptIds(), id];
    final trimmed = ids.length > keptPersonalLimit
        ? ids.sublist(ids.length - keptPersonalLimit)
        : ids;
    await _kept.writeJson(keptKey, {'ids': trimmed});
  }

  Future<List<SharedLineQuestion>> _recent() async {
    final t = _db.transactions;
    final a = _db.accounts;
    final since = now().subtract(sharedLineLookback);
    final rows =
        await (_db.select(t).join([innerJoin(a, a.id.equalsExp(t.accountId))])
              ..where(
                t.occurredAt.isBiggerOrEqualValue(since) &
                    t.direction.equalsValue(TransactionDirection.outflow) &
                    t.linkId.isNull() &
                    t.transferPairId.isNull() &
                    t.transferAccountId.isNull() &
                    t.categoryOverrideId.isNull() &
                    t.autoCategoryId.isNull() &
                    t.payeeId.isNull() &
                    a.type.isNotInValues([
                      AccountType.heldForSpace,
                      AccountType.ownersAccount,
                      AccountType.paidBySpace,
                    ]),
              )
              ..orderBy([OrderingTerm.desc(t.occurredAt)]))
            .get();
    final kept = await _keptIds();
    return [
      for (final row in rows)
        if (row.readTable(t) case final tx
            when !kept.contains(tx.id) &&
                tx.kind != TransactionKind.charge &&
                tx.kind != TransactionKind.fulizaRepayment &&
                tx.kind != TransactionKind.loanRepayment &&
                tx.kind != TransactionKind.correction)
          SharedLineQuestion(
            transactionId: tx.id,
            institutionId: row.readTable(a).institutionId ?? '',
            amountMinor: tx.amountMinor,
            currency: tx.currency,
            isInflow: false,
            at: tx.occurredAt,
            name: tx.counterpartyName,
            personKey: personKey(
              kind: tx.counterpartyKind,
              value: tx.counterpartyValue,
              name: tx.counterpartyName,
            ),
            onOwnAccount: true,
          ),
    ];
  }

  /// What is left to ask, once what was taught about each person applied.
  Future<List<SharedLineQuestion>> pending() async {
    final current = await rules();
    final out = <SharedLineQuestion>[];
    for (final q in await _recent()) {
      final to = q.personKey == null ? null : current.people[q.personKey];
      if (to == personalSpaceId) {
        await moves.forMe(q.transactionId);
      } else if (to == businessId) {
        await _keep(q.transactionId);
      } else {
        out.add(q);
      }
    }
    return out;
  }

  /// "Business cost" keeps it here; "This was for me" makes it Paid
  /// yourself, with the purchase in Personal.
  Future<void> answer(
    SharedLineQuestion question, {
    required bool forBusiness,
    required bool always,
  }) async {
    if (forBusiness) {
      await _keep(question.transactionId);
    } else {
      await moves.forMe(question.transactionId);
    }
    final key = question.personKey;
    if (always && key != null) {
      await remember(key, forBusiness ? businessId : personalSpaceId);
    }
  }
}

final ownAccountAskerProvider = Provider<OwnAccountAsker>(
  (ref) => OwnAccountAsker(
    business: ref.watch(appDatabaseProvider),
    businessId: ref.watch(activeSpaceIdProvider),
    moves: ref.watch(spaceMoveRepositoryProvider),
    rules: () => ref.read(routingRulesProvider.future),
    remember: (key, spaceId) =>
        ref.read(routingRulesProvider.notifier).rememberPerson(key, spaceId),
    now: ref.watch(clockProvider),
  ),
);

/// Payments the open business has to ask about; empty in Personal and in
/// spaces that are not a business. Payments out of its own accounts that
/// are unclear come first, then those on lines it shares with Personal.
final sharedLineQuestionsProvider = FutureProvider<List<SharedLineQuestion>>((
  ref,
) async {
  final space = ref.watch(activeSpaceProvider);
  if (space.kind != SpaceKind.business) return const [];
  ref.watch(routingRulesProvider);
  // Questions are a nudge: if Personal cannot be read, Home goes on without
  // them.
  try {
    return [
      ...await ref.watch(ownAccountAskerProvider).pending(),
      ...await ref.watch(sharedLineRouterProvider).pending(space.id),
    ];
  } on Object catch (error) {
    if (kDebugMode) debugPrint('Shared account questions failed: $error');
    return const [];
  }
});
