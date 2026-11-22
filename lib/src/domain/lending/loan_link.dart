/// What a transaction can be in Lent and borrowed, as the category picker
/// offers it in Personal-style spaces.
enum LoanLink {
  /// Money out lent to the payee: a new loan in Lent and borrowed.
  lent('I lent this', 'Adds it to Lent and borrowed'),

  /// Money out paying back the oldest money borrowed from the payee.
  repaidBorrowed('Paid back a loan', 'Lowers what you owe them'),

  /// Money in borrowed from the payee: added to Debts.
  borrowed('A loan to me', 'Added to Debts'),

  /// Money in paying back the oldest money lent to the payee.
  repaidLent('Paying me back', 'Lowers what they owe you');

  const LoanLink(this.label, this.hint);

  final String label;
  final String hint;

  /// What money out ([outflow]) or money in can be.
  static List<LoanLink> forDirection({required bool outflow}) =>
      outflow ? const [lent, repaidBorrowed] : const [borrowed, repaidLent];
}

/// How Activity names a transaction linked to a loan, in place of its
/// category: "Lent to Grace", "Borrowed from Grace".
String loanLinkLabel(LoanLink link, String person) => switch (link) {
  LoanLink.lent => 'Lent to $person',
  LoanLink.repaidBorrowed => 'Paid back to $person',
  LoanLink.borrowed => 'Borrowed from $person',
  LoanLink.repaidLent => 'Paid back by $person',
};
