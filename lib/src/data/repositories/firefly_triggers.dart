import '../database/app_database.dart';

/// The setting, in each space's own database, that says the space is being
/// sent to Firefly III. Its value is `true` while it is.
const fireflySendingKey = 'firefly.sending';

/// Adds the triggers that keep a space's Firefly III outbox (decision 0029,
/// section 5): while the space is being sent, every new, changed or deleted
/// transaction leaves a row in `firefly_outbox` in the same write, so
/// nothing is lost if the app stops before sending. The latest change wins:
/// a transaction keeps one row. One deleted before it was ever sent leaves
/// none, and one deleted after it was sent leaves a delete. Safe to run
/// again.
Future<void> createFireflyTriggers(AppDatabase db) async {
  const sending =
      "EXISTS (SELECT 1 FROM app_settings WHERE key = '$fireflySendingKey' "
      "AND value = 'true')";
  const now = "CAST(strftime('%s', 'now') AS INTEGER)";
  // Replaced rather than upserted: in a trigger, the conflict handling of
  // the statement that fired it would win over the trigger's own.
  String queue(String id) =>
      'DELETE FROM firefly_outbox WHERE transaction_id = $id; '
      'INSERT INTO firefly_outbox (transaction_id, action, queued_at, '
      "attempts, refused) VALUES ($id, 'send', $now, 0, 0);";
  final triggers = {
    'firefly_outbox_transaction_insert':
        'AFTER INSERT ON transactions WHEN $sending '
        'BEGIN ${queue('NEW.id')} END',
    'firefly_outbox_transaction_update':
        'AFTER UPDATE ON transactions WHEN $sending '
        'BEGIN ${queue('NEW.id')} END',
    'firefly_outbox_transaction_delete':
        'AFTER DELETE ON transactions WHEN $sending BEGIN '
        'DELETE FROM firefly_outbox WHERE transaction_id = OLD.id; '
        'INSERT INTO firefly_outbox (transaction_id, action, queued_at, '
        "attempts, refused) SELECT OLD.id, 'delete', $now, 0, 0 "
        'WHERE EXISTS (SELECT 1 FROM firefly_sent '
        'WHERE transaction_id = OLD.id); END',
  };
  for (final MapEntry(key: name, value: body) in triggers.entries) {
    await db.customStatement('CREATE TRIGGER IF NOT EXISTS $name $body');
  }
}
