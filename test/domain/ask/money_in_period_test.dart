import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/ask/answer.dart';
import 'package:pesaclarity/src/domain/ask/context.dart';
import 'package:pesaclarity/src/domain/ask/data_source.dart';
import 'package:pesaclarity/src/domain/ask/engine.dart';
import 'package:pesaclarity/src/domain/ask/matcher.dart';
import 'package:pesaclarity/src/domain/ask/periods.dart';
import 'package:pesaclarity/src/domain/ask/reply_writer.dart';
import 'package:pesaclarity/src/domain/ask/rule_question_reader.dart';
import 'package:pesaclarity/src/domain/ask/understanding.dart';
import 'package:pesaclarity/src/domain/enums.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_entry.dart';
import 'package:pesaclarity/src/domain/ledger/ledger_role.dart';
import 'package:pesaclarity/src/domain/time/calendar.dart';

import '../fixtures.dart';

/// "how much money got in during the 3 months", asked on 21 November 2026,
/// was answered "Money in · November 2026, KES 0: Nothing came in this
/// month", though money from named and unnamed senders had come in since
/// September. All of it made up.
void main() {
  final now = eat(2026, 11, 21, 10);
  final today = CalendarDate(2026, 11, 21);
  var id = 1;

  LedgerEntry inflow(
    DateTime at,
    int shillings, {
    TransactionKind kind = TransactionKind.received,
    int? payee,
    String? name,
    CategoryType? type,
    int? pair,
  }) => LedgerEntry(
    id: id++,
    accountId: 1,
    occurredAt: at,
    amountMinor: kes(shillings),
    direction: TransactionDirection.inflow,
    kind: kind,
    payeeId: payee,
    payeeName: payee == null ? null : name,
    counterpartyName: name,
    categoryType: type,
    transferPairId: pair,
  );

  /// September to November: KES 35,800 from named senders, KES 12,400
  /// from people not named yet, KES 7,000 moved from KCB, a KES 2,500
  /// Fuliza draw and a KES 600 refund. August's KES 9,000 is before.
  List<LedgerEntry> ledger() {
    final out = id++;
    final into = id++;
    return [
      inflow(
        eat(2026, 8, 28),
        9000,
        payee: 1,
        name: 'Example Employer',
        type: CategoryType.income,
      ),
      inflow(
        eat(2026, 9, 21),
        15000,
        payee: 1,
        name: 'Example Employer',
        type: CategoryType.income,
      ),
      inflow(
        eat(2026, 10, 21),
        15000,
        payee: 1,
        name: 'Example Employer',
        type: CategoryType.income,
      ),
      inflow(
        eat(2026, 11, 5),
        5800,
        payee: 2,
        name: 'Aunt Example',
        type: CategoryType.income,
      ),
      // Not named yet: no payee, no category.
      inflow(eat(2026, 9, 12), 4000, name: 'PERSON ONE'),
      inflow(eat(2026, 10, 30), 5000, name: 'PERSON TWO'),
      inflow(eat(2026, 11, 15), 3400, name: 'PERSON ONE'),
      // KCB to M-Pesa: the person's own money.
      LedgerEntry(
        id: out,
        accountId: 2,
        occurredAt: eat(2026, 10, 10),
        amountMinor: kes(7000),
        direction: TransactionDirection.outflow,
        kind: TransactionKind.bank,
        transferPairId: into,
      ),
      inflow(eat(2026, 10, 10), 7000, name: 'KCB', pair: out),
      inflow(eat(2026, 11, 2), 2500, kind: TransactionKind.fulizaDraw),
      inflow(eat(2026, 11, 8), 600, kind: TransactionKind.reversal),
      LedgerEntry(
        id: id++,
        accountId: 1,
        occurredAt: eat(2026, 11, 8),
        amountMinor: kes(1200),
        direction: TransactionDirection.outflow,
        kind: TransactionKind.till,
        categoryType: CategoryType.expense,
        counterpartyName: 'Example Shop',
      ),
    ];
  }

  late _Source source;
  late AskEngine engine;
  setUp(() {
    source = _Source(ledger());
    engine = AskEngine(
      source: source,
      reader: RuleQuestionReader(today: () => today),
    );
  });

  Future<AskAnswer> ask(String q, {AskEngine? using}) async =>
      (await (using ?? engine).ask(
        q,
        context: AskContext.empty,
        now: now,
      )).answer;

  String text(AskAnswer a) =>
      fillTemplate(a.template, a.facts, money: (m) => '${m ~/ 100}');

  final threeMonths = AskPeriod.lastMonths(3, today);

  group('the question as asked', () {
    test('all the money that arrived, September to November', () async {
      final a = await ask('how much money got in during the 3 months');
      expect(a.context.intent, AskIntent.received);
      expect(a.context.period, threeMonths);
      expect(a.context.period!.from, CalendarDate(2026, 9, 1));
      expect(a.context.period!.to, CalendarDate(2026, 11, 22));
      expect(a.headline, 'Money in · Sep to Nov 2026');
      // 35,800 named and 12,400 not named yet; not the own transfer, the
      // Fuliza draw, the refund or August.
      expect(a.figureMinor, kes(48200));
      expect(
        text(a),
        endsWith(
          "12400 of it is from people you haven't named yet. The 7000 that "
          "moved between your own accounts isn't counted as money in. The "
          "2500 you borrowed, such as Fuliza, isn't counted as money in.",
        ),
      );
      expect(text(a), isNot(contains('Nothing')));
      // Each sender, named or not, is a row; Activity opens on them.
      expect(a.rows.first.title, 'Example Employer');
      expect(a.totalRows, 4);
      expect(a.link, AskLink.activity);
    });

    test('the named part is what Insights and Home count as income', () {
      final named = ledger()
          .where(
            (e) =>
                threeMonths.contains(e.date) && roleOf(e) == LedgerRole.income,
          )
          .fold(0, (s, e) => s + e.amountMinor);
      expect(named, kes(48200 - 12400));
    });

    test('money in is all that arrived: the one definition', () {
      final arrived = {
        for (final e in ledger())
          if (isMoneyArrived(e)) e.amountMinor ~/ 100,
      };
      expect(arrived, {9000, 15000, 5800, 4000, 5000, 3400});
    });
  });

  group('every way of saying the period', () {
    final cases = <String, AskPeriod>{
      'how much money got in during the 3 months': threeMonths,
      'How much came in the last 3 months?': threeMonths,
      'money in over the past three months': threeMonths,
      'How much did I receive over the last 3 months?': threeMonths,
      'how much came in in these 3 months': threeMonths,
      'income 3 months': threeMonths,
      'How much did I get in the last three months': threeMonths,
      'How much came in the last quarter?': AskPeriod.quarter(
        YearMonth(2026, 7),
        today,
      ),
      'How much came in since September?': AskPeriod(
        PeriodKind.since,
        CalendarDate(2026, 9, 1),
        CalendarDate(2026, 11, 22),
      ),
      'How much came in the past 90 days?': AskPeriod(
        PeriodKind.days,
        CalendarDate(2026, 8, 24),
        CalendarDate(2026, 11, 22),
        length: 90,
      ),
    };
    for (final MapEntry(key: q, value: period) in cases.entries) {
      test(q, () async {
        final a = await ask(q);
        expect(a.context.intent, AskIntent.received, reason: q);
        expect(a.context.period, period, reason: q);
        expect(a.headline, 'Money in · ${period.label(today)}', reason: q);
      });
    }

    test('the last quarter is July to September', () async {
      final a = await ask('How much came in the last quarter?');
      expect(a.headline, 'Money in · Jul to Sep 2026');
      expect(a.figureMinor, kes(9000 + 4000 + 15000));
    });

    test('in Swahili', () async {
      for (final q in [
        'pesa iliyoingia miezi mitatu iliyopita',
        'Pesa ngapi zimeingia miezi 3 iliyopita?',
        'nilipokea pesa ngapi kwa miezi mitatu',
      ]) {
        final a = await ask(q);
        expect(a.context.intent, AskIntent.received, reason: q);
        expect(a.context.period, threeMonths, reason: q);
        expect(a.figureMinor, kes(48200), reason: q);
      }
      final since = await ask('pesa iliyoingia tangu Septemba');
      expect(since.context.period!.from, CalendarDate(2026, 9, 1));
    });
  });

  group('words of time Ask cannot read are said, never hidden', () {
    test('"the last few months" answers for this month and says so', () async {
      final a = await ask('How much came in over the last few months?');
      expect(a.context.period, isNull);
      expect(a.headline, 'Money in · November 2026');
      expect(
        text(a),
        endsWith(
          'I read this as this month; ask about “the last three months” or '
          '“this year” for more.',
        ),
      );
    });

    test(
      'a reader period that reads as none falls back to the words',
      () async {
        // As a trained reader might tag it: only part of the period.
        final tagged = AskEngine(
          source: source,
          reader: _Fixed(
            const Understanding(
              AskIntent.received,
              spans: [AskSpan(SlotKind.period, 'during the')],
            ),
          ),
        );
        final a = await ask(
          'how much money got in during the 3 months',
          using: tagged,
        );
        expect(a.context.period, threeMonths);
        expect(a.figureMinor, kes(48200));
        expect(text(a), isNot(contains('I read this as')));

        final none = await ask('how much money got in lately', using: tagged);
        expect(none.headline, 'Money in · November 2026');
        expect(text(none), contains('I read this as this month;'));
      },
    );

    test('a question with no words of time is this month, no note', () async {
      final a = await ask('How much came in?');
      expect(a.headline, 'Money in · November 2026');
      expect(text(a), isNot(contains('I read this as')));
    });
  });

  group('when nothing came in', () {
    test('nothing at all in the period', () async {
      source.all.removeWhere((e) => e.isInflow);
      final a = await ask('how much money got in during the 3 months');
      expect(a.kind, ReplyKind.nothingIn);
      expect(a.figureMinor, 0);
      expect(a.headline, 'Money in · Sep to Nov 2026');
      expect(text(a), 'No money came to you in the last 3 months.');
      final september = await ask('How much came in in September?');
      expect(text(september), 'No money came to you in September.');
    });

    test('only own money and borrowing: zero, and why', () async {
      source.all.removeWhere(isMoneyArrived);
      final a = await ask('how much money got in during the 3 months');
      expect(a.kind, ReplyKind.nothingIn);
      expect(a.figureMinor, 0);
      expect(
        text(a),
        'No money came to you in the last 3 months. The 7000 that moved '
        "between your own accounts isn't counted as money in. The 2500 you "
        "borrowed, such as Fuliza, isn't counted as money in.",
      );
    });
  });
}

class _Fixed implements QuestionReader {
  _Fixed(this.understanding);

  final Understanding understanding;

  @override
  Understanding read(String question) => understanding;

  @override
  void close() {}
}

class _Source implements AskDataSource {
  _Source(this.all);

  final List<LedgerEntry> all;

  @override
  Future<List<AskEntity>> entities() async => const [
    AskEntity(SlotKind.payee, 'p:1', 'Example Employer'),
    AskEntity(SlotKind.payee, 'p:2', 'Aunt Example'),
    AskEntity(SlotKind.account, 'a:1', 'M-Pesa'),
    AskEntity(SlotKind.account, 'a:2', 'KCB'),
  ];

  @override
  Future<List<AskShortcut>> shortcuts() async => const [];

  @override
  Future<List<LedgerEntry>> entries(DateTime from, DateTime to) async => [
    for (final e in all)
      if (!e.occurredAt.isBefore(from) && e.occurredAt.isBefore(to)) e,
  ];

  @override
  Future<AskSafeToSpend?> safeToSpend() async => null;

  @override
  Future<List<AskLine>> billsDue() async => const [];

  @override
  Future<List<AskLine>> subscriptions() async => const [];

  @override
  Future<List<AskLine>> debts() async => const [];

  @override
  Future<List<AskLine>> lent() async => const [];

  @override
  Future<List<AskLine>> owedToMe() async => const [];

  @override
  Future<List<AskLine>> goals() async => const [];

  @override
  Future<List<AskLine>> balances() async => const [];

  @override
  Future<AskLine> sales(AskPeriod period) async => const AskLine('Sales', 0);

  @override
  Future<List<AskLine>> itemsSold(AskPeriod period) async => const [];

  @override
  Future<int?> profit(AskPeriod period) async => null;

  @override
  Future<List<AskLine>> lowStock() async => const [];

  @override
  Future<int> fees(AskPeriod period) async => 0;
}
