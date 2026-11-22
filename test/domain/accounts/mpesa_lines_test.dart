// Two M-Pesa lines on one phone: keying a message to its line by SIM, and,
// where the phone reports none, by the balance it prints. Made-up amounts.
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/accounts/account_reference.dart';
import 'package:pesaclarity/src/domain/accounts/mpesa_lines.dart';

var _n = 0;

/// A payment of [shillings] (into the wallet with [inflow]) that leaves
/// [balance], on [sim], at minute [minute] of the day.
LineFacts _pay(
  int shillings,
  int? balance, {
  String? sim,
  bool inflow = false,
  int fee = 0,
  required int minute,
  String? hash,
}) => LineFacts(
  hash: hash ?? 'h${_n++}',
  at: DateTime.utc(2026, 11, 21, 6).add(Duration(minutes: minute)),
  sim: sim,
  amountMinor: shillings * 100,
  feeMinor: fee * 100,
  inflow: inflow,
  balanceMinor: balance == null ? null : balance * 100,
);

/// Places [facts] one after the other.
(MpesaLines, List<LinePlace>) _placeAll(
  List<LineFacts> facts, [
  MpesaLines from = MpesaLines.empty,
]) => from.placeAll(facts);

void main() {
  group('line keys', () {
    test('a line account reference is no account number', () {
      expect(lineReference('2'), 'line:2');
      expect(lineOfReference('line:2'), '2');
      expect(lineOfReference('0170****4321'), isNull);
      expect(AccountReference.tryParse(lineReference('1')), isNull);
      expect(lineSelectionId('2'), 'mpesa#2');
      expect(lineOfSelection('mpesa#2'), '2');
      expect(lineOfSelection('mpesa'), isNull);
    });

    test('a balance carries on, and Fuliza covers what is short', () {
      expect(carriesOn(1000000, _pay(500, 9500, minute: 0)), isTrue);
      expect(carriesOn(1000000, _pay(500, 9485, fee: 15, minute: 0)), isTrue);
      expect(
        carriesOn(1000000, _pay(2000, 12000, inflow: true, minute: 0)),
        isTrue,
      );
      expect(carriesOn(1000000, _pay(500, 9000, minute: 0)), isFalse);
      // 300 paid from 100: Fuliza lends the rest, the wallet is left at 0.
      expect(carriesOn(10000, _pay(300, 0, minute: 0)), isTrue);
      expect(carriesOn(null, _pay(300, 0, minute: 0)), isFalse);
      expect(carriesOn(10000, _pay(300, null, minute: 0)), isFalse);
    });
  });

  group('Android: by SIM', () {
    test('each SIM is its own line, in the order seen', () {
      final (lines, places) = _placeAll([
        _pay(500, 12000, sim: 'sim:3', minute: 0),
        _pay(300, 24000, sim: 'sim:5', minute: 1),
        _pay(200, 11800, sim: 'sim:3', minute: 2),
        _pay(100, 23900, sim: 'sim:5', minute: 3),
      ]);
      expect(places, const [
        OnLine('1'),
        OnLine('2'),
        OnLine('1'),
        OnLine('2'),
      ]);
      expect(lines.lines.map((l) => l.sims), [
        {'sim:3'},
        {'sim:5'},
      ]);
      expect(lines.line('1')!.balanceMinor, 1180000);
      expect(lines.line('2')!.messages, 2);
      expect(lines.line('1')!.slot, 'SIM 1');
      expect(lines.line('2')!.label, 'SIM 2');
      // In use at once and read as one: the split is offered.
      expect(lines.offersSplit, isTrue);
      expect(lines.twoSeen, isTrue);
    });

    test('one SIM alone offers nothing', () {
      final (lines, _) = _placeAll([
        _pay(500, 12000, sim: 'sim:3', minute: 0),
        _pay(200, 11800, sim: 'sim:3', minute: 2),
      ]);
      expect(lines.lines, hasLength(1));
      expect(lines.offersSplit, isFalse);
      expect(lines.twoSeen, isFalse);
    });

    test('a line replaced by a new SIM is not offered as a second', () {
      // Old SIM until minute 2; a new SIM from minute 10 that does not carry
      // on (a message was missed): two lines, never in use together.
      final (lines, _) = _placeAll([
        _pay(500, 12000, sim: 'sim:3', minute: 0),
        _pay(200, 11800, sim: 'sim:3', minute: 2),
        _pay(100, 5000, sim: 'sim:8', minute: 10),
        _pay(100, 4900, sim: 'sim:8', minute: 11),
      ]);
      expect(lines.lines, hasLength(2));
      expect(lines.offersSplit, isFalse);
    });

    test('a message read again is not counted twice', () {
      final first = _pay(500, 12000, sim: 'sim:3', minute: 5, hash: 'a');
      final (lines, _) = _placeAll([
        first,
        _pay(200, 11800, sim: 'sim:3', minute: 6, hash: 'b'),
      ]);
      final (again, places) = lines.placeAll([first]);
      expect(places, const [OnLine('1')]);
      expect(again.line('1')!.messages, 2);
      expect(again.line('1')!.balanceMinor, 1180000);
    });

    group('a new SIM after the split', () {
      MpesaLines split() {
        final (lines, _) = _placeAll([
          _pay(500, 12000, sim: 'sim:3', minute: 0),
          _pay(300, 24000, sim: 'sim:5', minute: 1),
        ]);
        return lines
            .copyWith(split: true)
            .withChoice('1', name: 'My line')
            .withChoice('2', name: 'Shop line', spaceId: 'shop1');
      }

      test('that carries on a line joins it without asking', () {
        final (lines, place) = split().place(
          _pay(1000, 11000, sim: 'sim:9', minute: 30),
        );
        expect(place, const OnLine('1'));
        expect(lines.line('1')!.sims, {'sim:3', 'sim:9'});
        expect(lines.newSims, isEmpty);
      });

      test('that carries on none waits for the question', () {
        var (lines, place) = split().place(
          _pay(1000, 9150, sim: 'sim:9', minute: 30),
        );
        expect(place, const WaitForSim('sim:9'));
        // Its next message waits too.
        final next = lines.place(_pay(150, 9000, sim: 'sim:9', minute: 31));
        expect(next.$2, const WaitForSim('sim:9'));
        expect(next.$1.newSims, hasLength(1));
        // Asked about the line used last first.
        final (q, line) = lines.nextSimQuestion!;
        expect(q.firstBalanceMinor, 915000);
        expect(line.label, 'Shop line');

        // Not the Shop line: asked about My line next.
        lines = lines.answerSim('sim:9', '2', same: false, listed: {'shop1'});
        expect(lines.nextSimQuestion!.$2.label, 'My line');
        lines = lines.answerSim('sim:9', '1', same: true, listed: {'shop1'});
        expect(lines.newSims, isEmpty);
        expect(lines.line('1')!.sims, contains('sim:9'));
        // Personal reads My line: it reads the SIM's messages again.
        expect(lines.readFrom, {'personal': q.firstAt});
        expect(
          lines.place(_pay(150, 9000, sim: 'sim:9', minute: 32)).$2,
          const OnLine('1'),
        );
        expect(lines.readDone('personal').readFrom, isEmpty);
      });

      test('that is neither line becomes a new one', () {
        var (lines, _) = split().place(
          _pay(1000, 9150, sim: 'sim:9', minute: 30),
        );
        lines = lines.answerSim('sim:9', '2', same: false, listed: {'shop1'});
        lines = lines.answerSim('sim:9', '1', same: false, listed: {'shop1'});
        expect(lines.newSims, isEmpty);
        expect(lines.line('3')!.sims, {'sim:9'});
        expect(lines.line('3')!.spaceId, 'personal');
        expect(lines.readFrom.keys, ['personal']);
      });
    });
  });

  group('iPhone: by the running balance', () {
    test('two interleaved lines are told apart and offered a split', () {
      final (lines, places) = _placeAll([
        _pay(500, 12000, minute: 0),
        _pay(300, 24000, minute: 1), // no line carries on to it: line 2
        _pay(200, 11800, minute: 2),
        _pay(100, 23900, minute: 3),
        _pay(1000, 24900, inflow: true, minute: 4),
      ]);
      expect(places, const [
        OnLine('1'),
        OnLine('2'),
        OnLine('1'),
        OnLine('2'),
        OnLine('2'),
      ]);
      expect(lines.line('1')!.slot, 'Line 1');
      expect(lines.bySim, isFalse);
      expect(lines.offersSplit, isTrue);
      // Placed by balance, so read again or by another space they go to
      // the same line.
      expect(lines.placed.values.toSet(), {'1', '2'});
    });

    test('a missed message on one line is not a second line', () {
      final (lines, _) = _placeAll([
        _pay(500, 12000, minute: 0),
        _pay(300, 11000, minute: 1), // one payment between was missed
        _pay(200, 10800, minute: 2),
        _pay(100, 10700, minute: 3),
      ]);
      // Line 1 stopped as line 2 began: never in use together.
      expect(lines.offersSplit, isFalse);
    });

    MpesaLines splitLines() {
      final (lines, _) = _placeAll([
        _pay(500, 12000, minute: 0),
        _pay(300, 24000, minute: 1),
        _pay(200, 11800, minute: 2),
        _pay(100, 23900, minute: 3),
      ]);
      return lines.copyWith(split: true);
    }

    test('after the split, one that fits neither line is asked', () {
      final (_, place) = splitLines().place(_pay(300, 5000, minute: 10));
      expect(place, const AskWhichLine());
    });

    test('one that fits both lines is asked', () {
      // Both lines at the same balance: the message cannot say which.
      final lines = MpesaLines.empty.copyWith(
        split: true,
        lines: const [
          MpesaLine(id: '1', balanceMinor: 1000000),
          MpesaLine(id: '2', balanceMinor: 1000000),
        ],
      );
      final (after, place) = lines.place(_pay(500, 9500, minute: 10));
      expect(place, const AskWhichLine());
      expect(after.placed, isEmpty);
    });

    test('one with no balance is asked once there are two lines', () {
      expect(
        splitLines().place(_pay(300, null, minute: 10)).$2,
        const AskWhichLine(),
      );
    });

    test('the answer places it, and the line carries on from it', () {
      final facts = _pay(300, 5000, minute: 10, hash: 'unsure');
      final lines = splitLines().placedOn(facts, '2');
      expect(lines.placed['unsure'], '2');
      expect(lines.line('2')!.balanceMinor, 500000);
      expect(lines.place(facts).$2, const OnLine('2'));
      expect(lines.place(_pay(200, 4800, minute: 11)).$2, const OnLine('2'));
    });

    test('stored transactions are sorted onto lines by their balance', () {
      final lines = splitLines();
      final stored = [
        StoredLineFacts(1, _pay(500, 12000, minute: 0, hash: 'x1')),
        StoredLineFacts(2, _pay(300, 24000, minute: 1, hash: 'x2')),
        StoredLineFacts(3, _pay(200, 11800, minute: 2, hash: 'x3')),
        StoredLineFacts(4, _pay(100, 23900, minute: 3, hash: 'x4')),
        StoredLineFacts(5, _pay(50, 11750, minute: 4, hash: 'x5')),
      ];
      expect(placeStored(lines, stored), {
        1: '1',
        2: '2',
        3: '1',
        4: '2',
        5: '1',
      });
    });
  });

  test('saved lines read back the same', () {
    final (placed, _) = _placeAll([
      _pay(500, 12000, sim: 'sim:3', minute: 0),
      _pay(300, 24000, sim: 'sim:5', minute: 1),
    ]);
    final lines = placed
        .copyWith(split: true, offerHidden: true)
        .withChoice('2', name: 'Shop line', spaceId: 'shop1')
        .place(_pay(1, 1, sim: 'sim:7', minute: 9))
        .$1;
    final back = MpesaLines.fromJson(lines.toJson());
    expect(back.toJson(), lines.toJson());
    expect(back.line('2')!.label, 'Shop line');
    expect(back.newSims.single.sim, 'sim:7');
    expect(MpesaLines.fromJson({'lines': 'nonsense'}).lines, isEmpty);
  });

  test('a line of a deleted space goes back to Personal', () {
    final lines = MpesaLines.empty.copyWith(
      lines: const [
        MpesaLine(id: '1'),
        MpesaLine(id: '2', spaceId: 'gone'),
        MpesaLine(id: '3', sharedWith: 'gone'),
      ],
    );
    expect(lines.readerOf(lines.line('2')!, {}), 'personal');
    final kept = lines.onlyFor({'shop1'});
    expect(kept.line('2')!.spaceId, 'personal');
    expect(kept.line('3')!.sharedWith, isNull);
  });

  test('the iPhone queue lets go of what every reading space has read', () {
    final lines = MpesaLines.empty.copyWith(
      split: true,
      lines: const [
        MpesaLine(id: '1'),
        MpesaLine(id: '2', spaceId: 'shop1'),
      ],
    );
    final t1 = DateTime.utc(2026, 11, 21, 8);
    final t2 = DateTime.utc(2026, 11, 21, 9);
    var (next, until) = lines.readTo('personal', t2, {'shop1'});
    // The shop has read nothing yet.
    expect(until, isNull);
    (next, until) = next.readTo('shop1', t1, {'shop1'});
    expect(until, t1);
    // Before the split, one space reads every line.
    expect(MpesaLines.empty.readTo('personal', t2, {}).$2, t2);
  });
}
