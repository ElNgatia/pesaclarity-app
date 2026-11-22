import '../reminders/reminder_schedule.dart';
import 'habit_settings.dart';

/// The id of the Sunday check-in notification, apart from the rest.
const checkInReminderId = collectReminderId + 16;

/// The Sunday check-in notification: the next Sunday at the chosen time,
/// today if it is Sunday and the time is still ahead of [now]. Safe on the
/// lock screen: no amounts and no categories. Null while the check-in or
/// its notification is off.
Reminder? checkInReminder({
  required DateTime now,
  required HabitSettings settings,
}) {
  final minute = settings.notifyMinuteOfDay;
  if (!settings.sundayCheckIn || minute == null) return null;
  final local = now.toLocal();
  final daysToSunday = (DateTime.sunday - local.weekday) % 7;
  var at = DateTime(
    local.year,
    local.month,
    local.day + daysToSunday,
    minute ~/ 60,
    minute % 60,
  );
  if (!at.isAfter(local)) {
    at = DateTime(at.year, at.month, at.day + 7, at.hour, at.minute);
  }
  return Reminder(
    id: checkInReminderId,
    kind: ReminderKind.weeklyCheckIn,
    at: at.toUtc(),
    title: 'Your week in three lines is ready',
    body: 'Open Pesa Clarity to read it.',
  );
}
