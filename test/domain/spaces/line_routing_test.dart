import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/domain/enums.dart';
import 'package:pesaclarity/src/domain/spaces/line_routing.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';

void main() {
  const rules = RoutingRules(
    sharedLines: {'mpesa': 'shop1', 'kcb': 'shop2'},
    people: {
      'phone:0700***002': 'shop1',
      'phone:0700***003': 'shop2',
      'name:mum': personalSpaceId,
    },
  );

  test('a space has its own rules: the lines it shares and its people', () {
    final shop = rules.forSpace('shop1');
    expect(shop.sharedLines, {'mpesa': 'shop1'});
    expect(shop.people, {'phone:0700***002': 'shop1'});
    expect(rules.forSpace('other9').isEmpty, isTrue);
    expect(rules.isEmpty, isFalse);
    expect(const RoutingRules().isEmpty, isTrue);
  });

  test('without a space, the others and Personal keep theirs', () {
    final left = rules.withoutSpace('shop1');
    expect(left.sharedLines, {'kcb': 'shop2'});
    expect(left.people, {
      'phone:0700***003': 'shop2',
      'name:mum': personalSpaceId,
    });
    expect(left.sharedWith('shop1'), isEmpty);
    expect(left.learntFor('shop1'), (business: 0, personal: 1));
  });

  test('only rules for spaces on the list stay; Personal is always on '
      'it', () {
    final left = rules.onlyFor({'shop2'});
    expect(left.sharedLines, {'kcb': 'shop2'});
    expect(left.people, {
      'phone:0700***003': 'shop2',
      'name:mum': personalSpaceId,
    });
    expect(rules.onlyFor({'shop1', 'shop2'}).toJson(), rules.toJson());
    expect(rules.onlyFor(const {}).people, {'name:mum': personalSpaceId});
  });

  test('putting a space\'s rules back keeps what was chosen since', () {
    final now = rules.withoutSpace('shop1');
    expect(now.withPutBack(rules.forSpace('shop1')).toJson(), rules.toJson());

    // The line is shared with another business now, and one of its people
    // was sent to Personal.
    final since = now
        .withLine('mpesa', 'shop2')
        .withPerson('phone:0700***002', personalSpaceId);
    final back = since.withPutBack(
      const RoutingRules(
        sharedLines: {'mpesa': 'shop1'},
        people: {'phone:0700***002': 'shop1', 'phone:0700***004': 'shop1'},
      ),
    );
    expect(back.sharedLines, {'mpesa': 'shop2', 'kcb': 'shop2'});
    expect(back.people['phone:0700***002'], personalSpaceId);
    expect(back.people['phone:0700***004'], 'shop1');
  });

  // Decision 0027, section 4: on a line used for both, the channel decides
  // first.
  group('channels on a line used for both', () {
    const pochi = ReceivedThrough(ChannelKind.ownPochi);
    const till = ReceivedThrough(ChannelKind.till, number: '123456');
    const number = ReceivedThrough(ChannelKind.ownNumber);
    const unclear = ReceivedThrough(ChannelKind.unclear);
    final shared = const RoutingRules().withNewShare('mpesa', 'stall');

    test("money into the owner's Pochi goes to the business, unasked", () {
      expect(shared.routeOf('mpesa', pochi).spaceId, 'stall');
    });

    test('a till the owner named goes to the business, unasked; one not '
        'seen is asked about once, and "No" falls back to the question', () {
      final route = shared.routeOf('mpesa', till);
      expect(route.asksNumber, isTrue);
      expect(route.number, '123456');
      final named = shared.withChannels(
        'mpesa',
        shared
            .channelsOn('mpesa')
            .withNumber(ChannelKind.till, '123456', 'stall'),
      );
      expect(named.routeOf('mpesa', till).spaceId, 'stall');
      final notOurs = shared.withChannels(
        'mpesa',
        shared.channelsOn('mpesa').withNotOurs(ChannelKind.till, '123456'),
      );
      final asked = notOurs.routeOf('mpesa', till);
      expect(asked.spaceId, isNull);
      expect(asked.asksNumber, isFalse);
    });

    test("money sent to the owner's number is personal, unless customers "
        'send to it too (owner\'s decision 15)', () {
      expect(shared.routeOf('mpesa', number).spaceId, personalSpaceId);
      final customers = shared.withChannels(
        'mpesa',
        shared.channelsOn('mpesa').copyWith(customersToNumber: true),
      );
      expect(customers.routeOf('mpesa', number).spaceId, isNull);
    });

    test('anything unclear is asked about, as today', () {
      expect(shared.routeOf('mpesa', unclear).spaceId, isNull);
      expect(shared.routeOf('mpesa', unclear).asksNumber, isFalse);
    });

    test('a line shared before channels keeps asking about money sent to '
        "the owner's number", () {
      final saved = RoutingRules.fromJson({
        'sharedLines': {'mpesa': 'stall'},
        'people': <String, String>{},
      });
      expect(saved.routeOf('mpesa', number).spaceId, isNull);
    });

    test('channels are saved and read back, and go with their space', () {
      final named = shared.withChannels(
        'mpesa',
        shared
            .channelsOn('mpesa')
            .withNumber(ChannelKind.paybill, '400200', 'stall')
            .withNotOurs(ChannelKind.till, '765432'),
      );
      final back = RoutingRules.fromJson(named.toJson());
      expect(back.channelsOn('mpesa').named, [(ChannelKind.paybill, '400200')]);
      expect(back.channelsOn('mpesa').notOurs, {'till:765432'});
      expect(back.channelsOn('mpesa').customersToNumber, isFalse);
      expect(named.withoutSpace('stall').channels, isEmpty);
      expect(named.forSpace('stall').channels.keys, ['mpesa']);
    });

    test('what a message rule says is the channel wins; until then money a '
        "person sent is sent to the owner's number", () {
      expect(
        receivedThrough(
          isInflow: true,
          kind: TransactionKind.received,
          counterpartyKind: PayeeIdentifierKind.phone,
        ),
        number,
      );
      expect(
        receivedThrough(
          isInflow: true,
          kind: TransactionKind.received,
          channel: till,
        ),
        till,
      );
      expect(
        receivedThrough(isInflow: true, kind: TransactionKind.bank),
        unclear,
      );
      expect(
        receivedThrough(isInflow: false, kind: TransactionKind.sent),
        unclear,
      );
    });

    test('a till or paybill is read from how the invoices say to pay', () {
      expect(channelFromPayLine('Till 123456'), (ChannelKind.till, '123456'));
      expect(channelFromPayLine('Paybill 400200 account 12'), (
        ChannelKind.paybill,
        '400200',
      ));
      expect(channelFromPayLine('Equity Bank'), isNull);
    });
  });
}
