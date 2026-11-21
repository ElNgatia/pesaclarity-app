import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/ask/periods.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';

void main() {
  // A Friday.
  final today = CalendarDate(2026, 11, 13);

  AskPeriod p(String text) => parsePeriod(text, today)!;

  group('parsePeriod', () {
    test('today and yesterday, in English and Swahili', () {
      expect(p('how much today').from, today);
      expect(p('leo').from, today);
      expect(p('yesterday').from, CalendarDate(2026, 11, 12));
      expect(p('jana').to, today);
    });

    test('this and last week run Monday to Sunday', () {
      expect(p('this week').from, CalendarDate(2026, 11, 9));
      expect(p('this week').to, CalendarDate(2026, 11, 14));
      final last = p('last week');
      expect(last.from, CalendarDate(2026, 11, 2));
      expect(last.to, CalendarDate(2026, 11, 9));
    });

    test('this month so far and last month whole', () {
      expect(p('this month').from, CalendarDate(2026, 11, 1));
      expect(p('this month').to, CalendarDate(2026, 11, 14));
      expect(p('mwezi huu').kind, PeriodKind.month);
      final last = p('last month');
      expect(last.from, CalendarDate(2026, 10, 1));
      expect(last.to, CalendarDate(2026, 11, 1));
    });

    test('years', () {
      expect(p('this year').from, CalendarDate(2026, 1, 1));
      expect(p('last year').from, CalendarDate(2025, 1, 1));
      expect(p('last year').to, CalendarDate(2026, 1, 1));
      expect(p('in 2025').from, CalendarDate(2025, 1, 1));
      expect(parsePeriod('in 2030', today), isNull);
    });

    test('month names, with and without a year', () {
      expect(p('in october').from, CalendarDate(2026, 10, 1));
      expect(p('october 2025').from, CalendarDate(2025, 10, 1));
      // December not yet come this year: last December.
      expect(p('in december').from, CalendarDate(2025, 12, 1));
      expect(p('sept').from.month, 9);
      // "may" alone is a word, not a month.
      expect(parsePeriod('may I ask', today), isNull);
      expect(p('in may').from, CalendarDate(2026, 5, 1));
    });

    test('since a month, and the last few months or days', () {
      final since = p('since june');
      expect(since.from, CalendarDate(2026, 6, 1));
      expect(since.to, CalendarDate(2026, 11, 14));
      final three = p('last 3 months');
      expect(three.from, CalendarDate(2026, 9, 1));
      expect(three.length, 3);
      expect(p('past six months').from, CalendarDate(2026, 6, 1));
      expect(p('last 7 days').from, CalendarDate(2026, 11, 7));
    });

    test('the last N months is this month and the N - 1 before', () {
      final three = AskPeriod.lastMonths(3, today);
      for (final q in [
        'the 3 months',
        'during the 3 months',
        'the last 3 months',
        'past three months',
        'over the last 3 months',
        'in these 3 months',
        '3 months',
        'for the previous three months',
        'miezi mitatu iliyopita',
        'miezi 3 iliyopita',
        'kwa miezi mitatu',
      ]) {
        expect(parsePeriod(q, today), three, reason: q);
      }
      expect(p('the last one month'), AskPeriod.lastMonths(1, today));
      expect(p('past twelve months').from, CalendarDate(2025, 12, 1));
    });

    test('not the months to come, nor the first of the year', () {
      expect(parsePeriod('the next 3 months', today), isNull);
      expect(parsePeriod('the coming three months', today), isNull);
      expect(parsePeriod('the first 3 months', today), isNull);
    });

    test('N months ago is that month', () {
      expect(p('3 months ago'), AskPeriod.month(YearMonth(2026, 8), today));
      expect(p('two months ago').from, CalendarDate(2026, 9, 1));
    });

    test('days and weeks, in words and Swahili', () {
      final ninety = p('the past 90 days');
      expect(ninety.kind, PeriodKind.days);
      expect(ninety.from, CalendarDate(2026, 8, 16));
      expect(ninety.to, CalendarDate(2026, 11, 14));
      expect(p('last ninety days'), ninety);
      expect(p('siku tisini zilizopita'), ninety);
      expect(p('the last 2 weeks').from, CalendarDate(2026, 10, 31));
      expect(p('wiki mbili zilizopita').length, 14);
      expect(p('these 30 days').length, 30);
    });

    test('quarters are calendar quarters', () {
      final last = p('the last quarter');
      expect(last.kind, PeriodKind.quarter);
      expect(last.from, CalendarDate(2026, 7, 1));
      expect(last.to, CalendarDate(2026, 10, 1));
      expect(p('past quarter'), last);
      expect(p('previous quarter'), last);
      final now = p('this quarter');
      expect(now.from, CalendarDate(2026, 10, 1));
      expect(now.to, CalendarDate(2026, 11, 14));
      expect(now.previous(), last);
      expect(last.label(today), 'Jul to Sep 2026');
      expect(last.phrase(today), 'last quarter');
      expect(now.phrase(today), 'this quarter');
      expect(AskPeriod.fromJson(last.toJson()), last);
    });

    test('since a month, in Swahili too', () {
      expect(p('tangu septemba'), p('since september'));
      expect(p('tangu septemba').from, CalendarDate(2026, 9, 1));
      expect(p('mwezi wa oktoba').from, CalendarDate(2026, 10, 1));
    });

    test('nothing named', () {
      expect(parsePeriod('how much did I spend on food', today), isNull);
    });

    test('finds where the words are', () {
      final m = findPeriod('Food last month please', today)!;
      expect(m.text, 'last month');
      expect(m.start, 5);
    });
  });

  group('unreadPeriod', () {
    test('words of time no rule reads', () {
      for (final q in [
        'over the last few months',
        'the past year',
        'last 2 years',
        'these days',
        'miezi kadhaa',
      ]) {
        expect(parsePeriod(q, today), isNull, reason: q);
        expect(unreadPeriod(q), isNotNull, reason: q);
      }
    });

    test('not words that say how, not when', () {
      for (final q in [
        'How much do I save a month?',
        'How has food changed each month?',
        'spending month by month',
        'sales by day',
        'What did I spend on food?',
        'What was my best day?',
      ]) {
        expect(unreadPeriod(q), isNull, reason: q);
      }
    });
  });

  group('previous', () {
    test('a month so far compares with the whole month before', () {
      final prev = AskPeriod.thisMonth(today).previous();
      expect(prev.from, CalendarDate(2026, 10, 1));
      expect(prev.to, CalendarDate(2026, 11, 1));
    });

    test('a week, a year, a day and N months', () {
      expect(
        AskPeriod.thisWeek(today).previous().from,
        CalendarDate(2026, 11, 2),
      );
      expect(AskPeriod.thisYear(today).previous().from.year, 2025);
      expect(
        AskPeriod.today(today).previous().from,
        CalendarDate(2026, 11, 12),
      );
      final three = AskPeriod.lastMonths(3, today).previous();
      expect(three.from, CalendarDate(2026, 6, 1));
      expect(three.to, CalendarDate(2026, 9, 1));
    });
  });

  group('labels', () {
    test('headings', () {
      expect(p('last month').label(today), 'October 2026');
      expect(p('this year').label(today), 'Jan to Nov 2026');
      expect(p('this week').label(today), 'Mon 9 to Fri 13 Nov');
      expect(p('today').label(today), 'Today');
    });

    test('phrases', () {
      expect(p('last month').phrase(today), 'last month');
      expect(p('in september').phrase(today), 'in September');
      expect(p('this year').phrase(today), 'this year');
      expect(p('october 2025').phrase(today), 'in October 2025');
    });

    test('the last N months reads as a stretch of months', () {
      final three = p('the 3 months');
      expect(three.label(today), 'Sep to Nov 2026');
      expect(three.phrase(today), 'in the last 3 months');
    });

    test('JSON round trip', () {
      final period = p('last 3 months');
      expect(AskPeriod.fromJson(period.toJson()), period);
    });
  });
}
