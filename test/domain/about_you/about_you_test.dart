import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/about_you/about_you.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';
import 'package:pesaclarity/src/features/sms/domain/pasted_messages.dart';

void main() {
  group('About you', () {
    test('keeps its answers and offers through JSON', () {
      final answers = AboutYou(
        who: WhoYouAre.working,
        matters: const {WhatMatters.saveSteadily, WhatMatters.payOffDebt},
        pays: const {RegularPayment.rent, RegularPayment.groceries},
        answered: true,
        offeredOn: CalendarDate(2026, 11, 22),
        homeOfferClosed: true,
      );
      final back = AboutYou.fromJson(answers.toJson());
      expect(back.who, WhoYouAre.working);
      expect(back.matters, answers.matters);
      expect(back.pays, answers.pays);
      expect(back.answered, isTrue);
      expect(back.offeredOn, CalendarDate(2026, 11, 22));
      expect(back.homeOfferClosed, isTrue);
      expect(back.goalOfferClosed, isFalse);
    });

    test('reads nothing saved, or names it does not know, as unanswered', () {
      final none = AboutYou.fromJson(null);
      expect(none.who, isNull);
      expect(none.answered, isFalse);
      final odd = AboutYou.fromJson(const {
        'who': 'astronaut',
        'pays': ['rent', 'yachts'],
        'offeredOn': 'soon',
      });
      expect(odd.who, isNull);
      expect(odd.pays, {RegularPayment.rent});
      expect(odd.offeredOn, isNull);
    });

    test('Home offers it once more from the day after setup', () {
      final day = CalendarDate(2026, 11, 22);
      final skipped = AboutYou(offeredOn: day);
      expect(skipped.homeOfferOn(day), isFalse);
      expect(skipped.homeOfferOn(day.addDays(1)), isTrue);
      expect(
        skipped.copyWith(homeOfferClosed: true).homeOfferOn(day.addDays(1)),
        isFalse,
      );
      expect(
        skipped.copyWith(answered: true).homeOfferOn(day.addDays(1)),
        isFalse,
      );
      expect(const AboutYou().homeOfferOn(day), isFalse);
    });

    test('Family is one of the three answers, and income is not asked', () {
      expect(WhoYouAre.values.map((w) => w.label), [
        'Student',
        'Working or in business',
        'Family',
      ]);
    });
  });

  group('Plan starts', () {
    test('round amounts up to plain figures', () {
      expect(roundUpForPlan(980000), 1000000);
      expect(roundUpForPlan(560000), 600000);
      expect(roundUpForPlan(2500000), 2500000);
      expect(roundUpForPlan(65000), 70000);
      expect(roundUpForPlan(0), 0);
    });

    test('with each picked payment the messages show, a month at a time', () {
      final starts = planStartFor(
        {
          RegularPayment.rent,
          RegularPayment.groceries,
          RegularPayment.utilities,
          RegularPayment.subscriptions,
        },
        {'rent': 7500000, 'groceries': 2940000, 'transport': 1680000},
      );
      expect(
        [for (final s in starts) (s.payment, s.categoryKey, s.amountMinor)],
        [
          (RegularPayment.rent, 'rent', 2500000),
          (RegularPayment.groceries, 'groceries', 1000000),
        ],
      );
    });
  });

  group('Goal suggestion', () {
    test('an emergency fund of a month, saved over a year', () {
      final goal = goalSuggestionFor(
        const AboutYou(matters: {WhatMatters.saveSteadily}),
        5710000,
      )!;
      expect(goal.name, 'Emergency fund');
      expect(goal.reason, 'You said saving steadily matters.');
      expect(goal.targetMinor, 5700000);
      expect(goal.monthlyMinor, 475000);
      expect(goal.halfMonth, isFalse);
    });

    test('half a month for a student; none for debt alone', () {
      final student = goalSuggestionFor(
        const AboutYou(
          who: WhoYouAre.student,
          matters: {WhatMatters.betterHabits},
        ),
        2000000,
      )!;
      expect(student.halfMonth, isTrue);
      expect(student.targetMinor, 1000000);
      expect(
        goalSuggestionFor(
          const AboutYou(matters: {WhatMatters.payOffDebt}),
          2000000,
        ),
        isNull,
      );
      expect(
        goalSuggestionFor(
          const AboutYou(who: WhoYouAre.family),
          2000000,
        )?.reason,
        'You said you look after a family.',
      );
      expect(
        goalSuggestionFor(
          const AboutYou(matters: {WhatMatters.saveSteadily}),
          0,
        ),
        isNull,
      );
    });
  });

  group('Pasted messages', () {
    const a =
        'SKM2CD34EF Confirmed. Ksh1,440.00 paid to GREEN BASKET GROCERS. on '
        '19/11/26 at 6:20 PM.';
    const b =
        'SKN7GH56JK Confirmed. You have received Ksh2,500.00 from JANE DOE.';
    const bank = 'Dear Customer, KES 3,000.00 has been debited\nRef: X1.';

    test('split at blank lines and at each M-Pesa code', () {
      expect(splitPastedMessages('$a\n$b'), [a, b]);
      expect(splitPastedMessages('  $a\r\n\r\n$bank\n \n$b\n'), [a, bank, b]);
      expect(splitPastedMessages('$a $b'), ['$a $b']);
      expect(splitPastedMessages('  \n\n '), isEmpty);
    });

    test('each paste goes after the last, a blank line between', () {
      expect(appendPaste('', a), a);
      expect(appendPaste('$a\n', b), '$a\n\n$b');
      expect(appendPaste(a, '  '), a);
    });

    test('say how many are pasted', () {
      expect(pastedCountLabel(0), 'Nothing pasted yet');
      expect(pastedCountLabel(1), '1 message pasted');
      expect(pastedCountLabel(13), '13 messages pasted');
    });
  });
}
