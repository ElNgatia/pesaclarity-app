import '../spaces/space.dart';
import 'hlc.dart';
import 'share_model.dart';

/// Two members changed the same field without seeing each other's change.
/// The later one by the clock wins; the other is kept in history.
class ShareConflict {
  const ShareConflict({required this.winner, required this.loser});

  final ShareChange winner;
  final ShareChange loser;
}

/// What opening an update file did, or would do.
class MergeOutcome {
  const MergeOutcome({
    required this.accepted,
    required this.refused,
    required this.conflicts,
    required this.added,
    required this.changed,
    required this.skipped,
  });

  /// Changes now in the log, in clock order.
  final List<ShareChange> accepted;

  /// Changes their author's role does not allow.
  final List<ShareChange> refused;
  final List<ShareConflict> conflicts;

  /// Records the file added, and records whose fields it changed.
  final Set<String> added;
  final Set<String> changed;

  /// Changes this phone already had: the same file opened twice.
  final int skipped;

  /// Records whose stored rows must be written again.
  Set<String> get touched => {
    for (final c in accepted) '${c.entity.name}|${c.record}',
  };
}

/// A shared space's log, as this phone has it: every change, and the
/// latest change for each record and field.
class ShareLog {
  ShareLog(
    this.ownerId,
    this.kind, [
    Iterable<ShareChange> changes = const [],
  ]) {
    for (final c in changes) {
      add(c);
    }
  }

  /// The member who made the space.
  final String ownerId;
  final SpaceKind kind;

  final _byId = <String, ShareChange>{};
  final _latest = <String, ShareChange>{};

  Iterable<ShareChange> get changes => _byId.values;
  bool has(String id) => _byId.containsKey(id);
  ShareChange? latest(ShareEntity e, String record, String field) =>
      _latest['${e.name}|$record|$field'];

  /// The clock after every change in the log.
  Hlc get clock =>
      _byId.values.fold(Hlc.zero, (top, c) => c.hlc > top ? c.hlc : top);

  void add(ShareChange c) {
    _byId[c.id] = c;
    final now = _latest[c.key];
    if (now == null || c.hlc > now.hlc) _latest[c.key] = c;
  }

  /// Whether [record] is in the space: added, and not removed by a later
  /// change. A removal made at the same time as an edit wins over it.
  bool exists(ShareEntity e, String record) {
    final insert = latest(e, record, insertField);
    if (insert == null) return false;
    final remove = latest(e, record, removeField);
    return remove == null || insert.hlc > remove.hlc;
  }

  /// A record's fields: its insert, with each later field change on top.
  Map<String, Object?>? fields(ShareEntity e, String record) {
    final insert = latest(e, record, insertField);
    if (insert == null || !exists(e, record)) return null;
    final out = Map<String, Object?>.of((insert.value! as Map).cast());
    final prefix = '${e.name}|$record|';
    for (final entry in _latest.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final c = entry.value;
      if (c.isInsert || c.isRemove) continue;
      // A field set again by a later insert ("Bring it back") keeps the
      // insert's value.
      if (c.hlc > insert.hlc) out[c.field] = c.value;
    }
    return out;
  }

  /// Who added [record], and who typed it in for them.
  (String, String?)? addedBy(ShareEntity e, String record) {
    ShareChange? first;
    for (final c in _byId.values) {
      if (c.entity == e && c.record == record && c.isInsert) {
        if (first == null || first.hlc > c.hlc) first = c;
      }
    }
    return first == null ? null : (first.author, first.recordedBy);
  }

  /// Each member as the log has them now.
  Map<String, ShareMember> get members {
    final out = <String, ShareMember>{};
    final ids = {
      for (final c in _byId.values)
        if (c.entity == ShareEntity.member) c.record,
    };
    for (final id in ids) {
      final insert = latest(ShareEntity.member, id, insertField);
      if (insert == null) continue;
      final f = fields(ShareEntity.member, id);
      final removed = f == null;
      final v = f ?? Map<String, Object?>.of((insert.value! as Map).cast());
      out[id] = ShareMember(
        id: id,
        name: v['name'] as String? ?? '',
        role: ShareRole.byName(v['role']) ?? ShareRole.viewer,
        publicKey: (v['key'] as List?)?.cast<int>(),
        hasAccount: v['account'] == true,
        removed: removed,
      );
    }
    return out;
  }

  ShareRole? roleOf(String memberId) {
    final m = members[memberId];
    if (m == null || m.removed) return null;
    return m.role;
  }

  /// Whether [memberId]'s role lets them make [c].
  bool allows(String memberId, ShareChange c) {
    // The member list is only the Owner's to change. The space's first
    // owner is who made it, before any member record exists.
    final role = memberId == ownerId && roleOf(memberId) == null
        ? ShareRole.owner
        : roleOf(memberId);
    if (role == null || !role.canSend) return false;
    return switch (c.entity) {
      // Anyone may change their own name in the space, and say they have
      // an account.
      ShareEntity.member =>
        role == ShareRole.owner ||
            (c.record == memberId &&
                (c.field == 'name' || c.field == 'account')),
      ShareEntity.transaction => true,
      // In a chama only the Owner and Treasurer change the plan, accounts
      // and categories. In a Household every member may.
      ShareEntity.budget || ShareEntity.category || ShareEntity.account =>
        kind != SpaceKind.savingsGroup ||
            role == ShareRole.owner ||
            role == ShareRole.treasurer,
    };
  }

  /// Takes in [incoming], sent by [sender]. Nothing is added when the
  /// sender may not send (a Viewer, or someone removed): the whole file is
  /// refused with [ShareRefused].
  MergeOutcome merge(String sender, List<ShareChange> incoming) {
    final senderRole = roleOf(sender);
    if (senderRole == null) throw const ShareRefused.notMember();
    if (!senderRole.canSend) throw const ShareRefused.viewer();
    final sorted = [...incoming]..sort((a, b) => a.hlc.compareTo(b.hlc));
    final accepted = <ShareChange>[];
    final refused = <ShareChange>[];
    final conflicts = <ShareConflict>[];
    final added = <String>{};
    final changed = <String>{};
    var skipped = 0;
    for (final c in sorted) {
      if (has(c.id)) {
        skipped++;
        continue;
      }
      // The clock names its member: a change claiming to be by someone
      // else is refused, unless it is typed in for them.
      if (c.hlc.node != (c.recordedBy ?? c.author) || !allows(c.hlc.node, c)) {
        refused.add(c);
        continue;
      }
      final now = latest(c.entity, c.record, c.field);
      if (!c.isInsert &&
          !c.isRemove &&
          now != null &&
          now.hlc.node != c.hlc.node &&
          now.hlc != c.base &&
          now.value != c.value &&
          (c.base == null || now.hlc > c.base!)) {
        conflicts.add(
          c.hlc > now.hlc
              ? ShareConflict(winner: c, loser: now)
              : ShareConflict(winner: now, loser: c),
        );
      }
      final existed = exists(c.entity, c.record);
      add(c);
      accepted.add(c);
      if (c.isInsert && !existed) {
        added.add(c.record);
      } else {
        changed.add(c.record);
      }
    }
    changed.removeAll(added);
    return MergeOutcome(
      accepted: accepted,
      refused: refused,
      conflicts: conflicts,
      added: added,
      changed: changed,
      skipped: skipped,
    );
  }
}

/// Why a whole update file was refused.
class ShareRefused implements Exception {
  const ShareRefused(this.message);
  const ShareRefused.viewer()
    : message = 'This file is from a Viewer. Viewers only receive updates.';
  const ShareRefused.notMember()
    : message = 'This file is from someone who is not in this space.';
  const ShareRefused.unreadable()
    : message =
          "This file can't be opened. It was changed, or it is for another "
          'space or person.';

  final String message;

  @override
  String toString() => 'ShareRefused: $message';
}
