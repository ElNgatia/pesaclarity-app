/// The words of keeping a goal aside.
abstract final class GoalsAsideText {
  static const keepItAside = 'Keep it aside';
  static const keptAside = 'Kept aside';
  static const notABankLock =
      'This is not a bank lock. The money stays where it is and you can still '
      'spend it. Pesa Clarity just stops counting it as free.';

  /// `The 20,000 saved leaves Safe to spend and On hand`.
  static String keepItAsideDetail(String? saved) => saved == null
      ? 'What is saved leaves Safe to spend and On hand'
      : 'The $saved saved leaves Safe to spend and On hand';

  // On hand.
  static const setAsideForGoals = 'Set aside for goals';
  static const onHandNote =
      'Safe to spend leaves out what you keep aside for goals. Turn it off on '
      'the goal.';

  /// `20,000 set aside for goals`.
  static String setAsideLine(String amount) => '$amount set aside for goals';

  /// `18,500 of 20,000 still aside`.
  static String stillAside(String left, String all) =>
      '$left of $all still aside';

  /// Safe to spend's line once the free money is used up.
  static const nothingFree = 'Nothing free after what you set aside';

  // A dip.
  /// `You dipped KES 1,500 into School fees`.
  static String dipped(String amount, String goal) =>
      'You dipped $amount into $goal';
  static const dipDetail =
      'Your free money ran out, so this came from what you set aside';

  /// `It happens. The goal still shows 20,000 saved, but only 18,500 is
  /// aside now.`
  static String dipSubtitle(String saved, String aside) =>
      'It happens. The goal still shows $saved saved, but only $aside is '
      'aside now.';
  static const whatToDo = 'What to do';
  static const topUp = 'Top it up from the next money in';

  /// `Lower saved to 18,500`.
  static String lower(String to) => 'Lower saved to $to';
  static const leave = 'Leave it as it is';

  /// `The 1,500 comes back to the goal first when money comes in. Nothing
  /// moves in your bank or M-Pesa.`
  static String topUpNote(String dip) =>
      'The $dip comes back to the goal first when money comes in. Nothing '
      'moves in your bank or M-Pesa.';

  /// `School fees shows 18,500 of 45,000, and its monthly pace goes up to
  /// 13,250.`
  static String lowerNote(
    String goal,
    String saved,
    String target, {
    String? pace,
  }) =>
      '$goal shows $saved of $target'
      '${pace == null ? '.' : ', and its monthly pace goes up to $pace.'}';

  /// What leaving it means.
  static String leaveNote(String goal, String saved, String aside) =>
      '$goal still shows $saved saved, and $aside stays aside. Nothing moves '
      'in your bank or M-Pesa.';
}
