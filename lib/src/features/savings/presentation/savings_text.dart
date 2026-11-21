import '../../../domain/savings/savings_product.dart';
import '../../../domain/time/calendar.dart';
import '../../../domain/time/date_labels.dart';
import '../../../shared/format/date_labels.dart' show weekdayName;

/// The words of the savings screens, in one place: the question in
/// Activity, Add Chumz, a savings account's page, its sheets and its card
/// in My accounts.
abstract final class SavingsText {
  // The question under a payment in Activity.
  static String promptTitle(SavingsProduct product) =>
      'Is this your ${product.name} savings?';
  static String promptBody(SavingsProduct product, String paidTo) =>
      'You paid $paidTo, which runs ${product.name}. Add it as a savings '
      'account so payments count as saving, not spending.';
  static String add(SavingsProduct product) => 'Add ${product.name}';
  static const notMine = "It's not mine";
  static String declined(SavingsProduct product) =>
      'Payments to ${product.name} stay as they are. You can add it from '
      'My accounts › Add or remove accounts.';

  /// The line shown once under the payment after adding.
  static String added(String name, int updated) => updated == 0
      ? '$name added'
      : '$name added · $updated older '
            '${updated == 1 ? 'payment' : 'payments'} updated';

  // Add Chumz.
  static const name = 'Name';
  static const provider = 'Provider';
  static const paidThrough = 'Paid through';
  static const goalsFound = 'Goals found';
  static const fromCodes = 'From your account codes';
  static const nameThisGoal = 'name this goal';
  static const noCode = 'No account code';
  static const goalHint = 'Such as School fees';
  static const lockedUntil = 'Locked until';
  static const chooseDay = 'Choose a day';
  static const currentBalance = 'Current balance (optional)';
  static const goalBalance = 'Balance (optional)';
  static String typeWhatItShows(SavingsProduct? product, String name) =>
      'Type what ${product?.name ?? name} shows. You can update it any time.';
  static const addButton = 'Add';
  static String nameMissing(SavingsProduct product) =>
      'Enter a name, such as ${product.name}.';
  static const balanceLater =
      'Added. Type the balance on its page once each withdrawal has a goal.';

  // A savings account's page.
  static const saved = 'Saved';
  static const balance = 'Balance';
  static String heldBy(SavingsProduct? product) => product == null
      ? 'A savings account'
      : 'Held by ${product.provider} · paid in from ${_via(product)}';
  static String setByYou(String day) => 'Set by you · $day';
  static const fromPayments = 'From your payments so far';
  static const updateBalance = 'Update balance';
  static String noInterestSms(String name) =>
      "$name doesn't send interest by SMS. It shows here when you update "
      'the balance.';
  static const putIn = 'Put in so far';
  static const takenOut = 'Taken out';
  static const interestSoFar = 'Interest so far';
  static const wasThereBefore = 'Was there before';
  static const otherChanges = 'Other changes';
  static const goals = 'Goals';
  static const recent = 'Recent';
  static const nothingYet = 'Money in and out shows here.';
  static String lockedLine(CalendarDate until, String code, int thisYear) =>
      _withCode('Locked until ${dayLabel(until, thisYear: thisYear)}', code);
  static String openLine(String code) => _withCode('Open', code);
  static String notYours(String code) => _withCode('Not yours', code);
  static String ofTarget(String target) => 'of $target';
  static const balanceUpdated = 'Balance updated';
  static String includesInterest(String amount) => 'Includes $amount interest';
  static String includesBefore(String amount) => '$amount was there before';
  static String includesOther(String amount) => '$amount other changes';
  static const noChange = 'No change';
  static String fromAccount(String account) => 'From $account';
  static String withdrawnTo(String account) => 'Withdrawn to $account';
  static const ownTransfer = 'Own transfer';
  static const whichGoal = 'Which goal?';
  static const showMore = 'Show more';
  static const changeName = 'Change name';
  static String remove(String name) => 'Remove $name';
  static String removeTitle(String name) => 'Remove $name?';
  static String removeBody(String name) =>
      'Payments to $name count as spending again, and its goals, balances '
      'and interest go. You can add it again from My accounts › Add or '
      'remove accounts.';
  static const removeAction = 'Remove';
  static String removed(String name) => '$name removed.';
  static const undoUpdate = 'Undo this update';
  static String undoUpdateBody(String day) =>
      'The balances typed on $day go, and the interest they showed.';
  static const updateUndone = 'Update undone.';

  // Update balance.
  static String updateIntro(String name) => 'Type what $name shows now.';
  static String balanceOf(String pocket) => pocket;
  static const whichGoalTitle = 'Which goal was it from?';
  static String withdrawal(String amount, String day) =>
      'Withdrawn $amount · $day';
  static const chooseGoal = 'Choose a goal';
  static const chooseEach = 'Choose a goal for each withdrawal.';
  static const interestRule =
      'Anything above what you put in shows as interest.';
  static const save = 'Save';
  static const balanceSaved = 'Balance updated.';

  // A goal of a savings account.
  static const goalName = 'Goal name';
  static String notMineCode(String code) =>
      code.isEmpty ? 'This money is not mine' : 'This code is not mine';
  static const mineAfterAll = "It's mine after all";
  static const notMineNote =
      'Its payments then count as they did before, as spending.';

  // My accounts and Add or remove accounts.
  static const savingsApps = 'Savings apps';
  static String rowName(String name, SavingsProduct? product) =>
      product == null || product.provider == name
      ? name
      : '$name · ${product.provider}';
  static String goalsLine(int goals, int locked) => [
    '$goals ${goals == 1 ? 'goal' : 'goals'}',
    if (locked > 0) '$locked locked',
  ].join(' · ');
  static String fedBy(SavingsProduct? product) {
    final via = product == null ? 'M-Pesa' : _via(product);
    return 'Outside $via · you pay in from $via';
  }

  static String addAgain(SavingsProduct product) =>
      'Paid through ${product.paidThrough}';

  // Goals.
  static String savedIn(String account) => 'Saved in $account';
  static String lockedUntilDay(CalendarDate day, int thisYear) =>
      'Locked until ${dayLabel(day, thisYear: thisYear)}';
  static const savedInLabel = 'Saved in';
  static const typedByYou = 'Nowhere, I type it';
  static const typedByYouDetail = 'What is saved is what you type';

  /// `Sat 21 Nov`, with the year when it is not [thisYear].
  static String day(CalendarDate date, int thisYear) =>
      '${weekdayName(date).substring(0, 3)} ${dayLabel(date, thisYear: thisYear)}';

  static String _withCode(String lead, String code) =>
      code.isEmpty ? lead : '$lead · $code';

  /// `M-Pesa`, from `M-Pesa paybill NABO CAPITAL LTD`.
  static String _via(SavingsProduct product) =>
      product.paidThrough.split(' ').first;
}
