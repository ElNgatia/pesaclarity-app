import '../enums.dart';
import 'space.dart';

/// Where one money line (an institution such as M-Pesa or a bank) is read.
enum LineChoice {
  /// Only the business reads it.
  thisBusiness,

  /// Only Personal reads it.
  personal,

  /// Personal reads it, and the business asks about each payment ("Was this
  /// for the business?").
  both,
}

/// Which lines are shared with which business, and what the owner has
/// taught the app about people on those lines. Kept in Personal's settings,
/// so every space sees the same rules.
class RoutingRules {
  const RoutingRules({
    this.sharedLines = const {},
    this.people = const {},
    this.channels = const {},
  });

  /// Reads saved rules; anything malformed is left out.
  ///
  /// Lines shared before channels (decision 0027, section 4) have none
  /// saved, and keep asking about money sent to the owner's number, as they
  /// did (see [channelsOn]).
  factory RoutingRules.fromJson(Map<String, Object?>? json) {
    Map<String, String> strings(Object? raw) => {
      if (raw is Map)
        for (final MapEntry(:key, :value) in raw.entries)
          if (key is String && value is String) key: value,
    };
    final raw = json?['channels'];
    final channels = <String, LineChannels>{
      if (raw is Map)
        for (final MapEntry(:key, :value) in raw.entries)
          if (key is String && value is Map)
            key: LineChannels.fromJson(value.cast<String, Object?>()),
    };
    return RoutingRules(
      sharedLines: strings(json?['sharedLines']),
      people: strings(json?['people']),
      channels: channels,
    );
  }

  /// Institution id to the business space that shares it with Personal.
  final Map<String, String> sharedLines;

  /// [personKey] to the space their money goes to: a business space id, or
  /// [personalSpaceId].
  final Map<String, String> people;

  /// The business's own channels on each line (decision 0027, section 4),
  /// by institution id.
  final Map<String, LineChannels> channels;

  Map<String, Object?> toJson() => {
    'sharedLines': sharedLines,
    'people': people,
    if (channels.isNotEmpty)
      'channels': {
        for (final MapEntry(:key, :value) in channels.entries)
          key: value.toJson(),
      },
  };

  /// The channels on [line], none named by default. A line with none saved
  /// (shared before channels were kept, or shared by itself when a second
  /// space read it) still asks about money sent to the owner's number, as
  /// it did; a line the owner sets to "Used for both" starts with that off
  /// (owner's decision 15, see [withNewShare]).
  LineChannels channelsOn(String line) =>
      channels[line] ?? const LineChannels(customersToNumber: true);

  RoutingRules withChannels(String line, LineChannels value) => RoutingRules(
    sharedLines: sharedLines,
    people: people,
    channels: {...channels, line: value},
  );

  /// Where money that came in on [line] through [channel] goes, before
  /// anyone is asked (decision 0027, section 4: the channel decides
  /// first). Money out keeps today's rule and is always asked.
  ChannelRoute routeOf(String line, ReceivedThrough channel) {
    final business = sharedLines[line];
    if (business == null) return const ChannelRoute.ask();
    final named = channelsOn(line);
    switch (channel.kind) {
      case ChannelKind.ownPochi:
        // One Pochi per line: the business's (0026 decision 5).
        return ChannelRoute.to(named.pochiSpaceId ?? business);
      case ChannelKind.till || ChannelKind.paybill:
        final number = channel.number;
        if (number == null) return const ChannelRoute.ask();
        final space = named.spaceOf(channel.kind, number);
        if (space != null) return ChannelRoute.to(space);
        // Asked once; "No" falls back to the business-or-personal
        // question (approved screens, choice 4).
        if (named.notOurs.contains(named.keyOf(channel.kind, number))) {
          return const ChannelRoute.ask();
        }
        return ChannelRoute.askNumber(channel.kind, number);
      case ChannelKind.ownNumber:
        return named.customersToNumber
            ? const ChannelRoute.ask()
            : const ChannelRoute.to(personalSpaceId);
      case ChannelKind.unclear:
        return const ChannelRoute.ask();
    }
  }

  /// The lines Personal shares with [businessId].
  Set<String> sharedWith(String businessId) => {
    for (final MapEntry(:key, :value) in sharedLines.entries)
      if (value == businessId) key,
  };

  RoutingRules withLine(String institutionId, String? businessId) =>
      RoutingRules(
        sharedLines: {
          for (final MapEntry(:key, :value) in sharedLines.entries)
            if (key != institutionId) key: value,
          institutionId: ?businessId,
        },
        people: people,
        channels: businessId == null
            ? {
                for (final MapEntry(:key, :value) in channels.entries)
                  if (key != institutionId) key: value,
              }
            : channels,
      );

  /// These rules with [institutionId] newly used for both by [businessId],
  /// as the owner sets it in Business or personal: money sent to the
  /// owner's number is personal until they say customers send to it too
  /// (owner's decision 15).
  RoutingRules withNewShare(String institutionId, String businessId) {
    final shared = withLine(institutionId, businessId);
    if (sharedLines[institutionId] == businessId) return shared;
    return shared.withChannels(institutionId, const LineChannels());
  }

  RoutingRules withPerson(String key, String spaceId) => RoutingRules(
    sharedLines: sharedLines,
    people: {...people, key: spaceId},
    channels: channels,
  );

  bool get isEmpty => sharedLines.isEmpty && people.isEmpty && channels.isEmpty;

  /// These rules once the [lines] that Personal and [spaceId] both read are
  /// left to Personal: a [business] shares each with Personal, so it asks
  /// about its payments, unless the line is shared with another business
  /// already. Any other space gets no rule.
  RoutingRules readOnce(
    Set<String> lines, {
    required String spaceId,
    required bool business,
  }) {
    if (!business) return this;
    var next = this;
    for (final line in lines) {
      if ((sharedLines[line] ?? spaceId) == spaceId) {
        next = next.withLine(line, spaceId);
      }
    }
    return next;
  }

  /// Only the rules that send money to [spaceId]: the lines it shares with
  /// Personal and the people learnt for it.
  RoutingRules forSpace(String spaceId) => RoutingRules(
    sharedLines: {
      for (final MapEntry(:key, :value) in sharedLines.entries)
        if (value == spaceId) key: value,
    },
    people: {
      for (final MapEntry(:key, :value) in people.entries)
        if (value == spaceId) key: value,
    },
    channels: {
      for (final MapEntry(:key, :value) in channels.entries)
        if (sharedLines[key] == spaceId) key: value,
    },
  );

  /// These rules without those that send money to [spaceId].
  RoutingRules withoutSpace(String spaceId) => RoutingRules(
    sharedLines: {
      for (final MapEntry(:key, :value) in sharedLines.entries)
        if (value != spaceId) key: value,
    },
    people: {
      for (final MapEntry(:key, :value) in people.entries)
        if (value != spaceId) key: value,
    },
    channels: {
      for (final MapEntry(:key, :value) in channels.entries)
        if (sharedLines[key] != spaceId) key: value,
    },
  );

  /// These rules without any that send money to a space outside
  /// [spaceIds]. Personal is always there. Rules never outlive their space.
  RoutingRules onlyFor(Set<String> spaceIds) => RoutingRules(
    sharedLines: {
      for (final MapEntry(:key, :value) in sharedLines.entries)
        if (spaceIds.contains(value)) key: value,
    },
    people: {
      for (final MapEntry(:key, :value) in people.entries)
        if (value == personalSpaceId || spaceIds.contains(value)) key: value,
    },
    channels: {
      for (final MapEntry(:key, :value) in channels.entries)
        if (!sharedLines.containsKey(key) ||
            spaceIds.contains(sharedLines[key]))
          key: value,
    },
  );

  /// These rules with [older] ones put back, for a space that returns.
  /// Whatever was chosen since stays: a line shared with another business
  /// now, or a person sent elsewhere, is not taken back.
  RoutingRules withPutBack(RoutingRules older) => RoutingRules(
    sharedLines: {...older.sharedLines, ...sharedLines},
    people: {...older.people, ...people},
    channels: {...older.channels, ...channels},
  );

  /// How many people go to [businessId] and how many stay personal.
  ({int business, int personal}) learntFor(String businessId) {
    var business = 0;
    var personal = 0;
    for (final space in people.values) {
      if (space == businessId) business++;
      if (space == personalSpaceId) personal++;
    }
    return (business: business, personal: personal);
  }
}

/// A stable key for the other party of a transaction, the same in every
/// space: their normalised identifier when the message gave one, else their
/// name. Null when there is neither.
String? personKey({PayeeIdentifierKind? kind, String? value, String? name}) {
  if (kind != null && value != null && value.trim().isNotEmpty) {
    return '${kind.name}:${value.trim()}';
  }
  final n = name?.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  return n == null || n.isEmpty ? null : 'name:$n';
}

/// What the owner picks for a line, from where it is read now.
LineChoice lineChoiceOf({
  required bool inBusiness,
  required bool inPersonal,
  required bool shared,
}) {
  if (shared) return LineChoice.both;
  if (inBusiness && !inPersonal) return LineChoice.thisBusiness;
  if (inPersonal && !inBusiness) return LineChoice.personal;
  // Read in both without sharing is left to Personal and shared when the
  // business next opens (`readOnce`); show it as shared until then.
  return inBusiness ? LineChoice.both : LineChoice.personal;
}

/// How money came in on a line (decision 0027, section 4). Reading this
/// from a message needs a rule written from the owner's own samples; until
/// one exists only money sent to the owner's number is told apart, and the
/// rest is [ChannelKind.unclear], asked about as before.
enum ChannelKind {
  /// Into the owner's own Pochi la Biashara.
  ownPochi,

  /// Into a Lipa na M-Pesa till (Buy Goods).
  till,

  /// Into a paybill.
  paybill,

  /// Sent to the owner's own number.
  ownNumber,

  /// Anything else: an unknown sender, a bank, a reversal.
  unclear,
}

/// The channel one payment came in through, and its till or paybill
/// number when it has one.
class ReceivedThrough {
  const ReceivedThrough(this.kind, {this.number});

  final ChannelKind kind;
  final String? number;

  @override
  bool operator ==(Object other) =>
      other is ReceivedThrough && other.kind == kind && other.number == number;

  @override
  int get hashCode => Object.hash(kind, number);
}

/// The channel money came in through, from what a transaction keeps of its
/// message. [channel] is what a message rule says, once rules for money
/// received through the owner's Pochi, till or paybill exist (they wait on
/// the owner's samples); without it, money a person sent is sent to the
/// owner's number, and anything else is unclear.
ReceivedThrough receivedThrough({
  required bool isInflow,
  required TransactionKind kind,
  PayeeIdentifierKind? counterpartyKind,
  ReceivedThrough? channel,
}) {
  if (channel != null) return channel;
  if (!isInflow) return const ReceivedThrough(ChannelKind.unclear);
  if (kind == TransactionKind.received &&
      (counterpartyKind == null ||
          counterpartyKind == PayeeIdentifierKind.phone)) {
    return const ReceivedThrough(ChannelKind.ownNumber);
  }
  return const ReceivedThrough(ChannelKind.unclear);
}

/// What [RoutingRules.routeOf] decides.
class ChannelRoute {
  /// Goes to [spaceId] without a question.
  const ChannelRoute.to(String this.spaceId) : kind = null, number = null;

  /// Asked as today: "Was this for the business?".
  const ChannelRoute.ask() : spaceId = null, kind = null, number = null;

  /// Asked once: "Is till 123456 Vegetable stall's?".
  const ChannelRoute.askNumber(ChannelKind this.kind, String this.number)
    : spaceId = null;

  final String? spaceId;
  final ChannelKind? kind;
  final String? number;

  bool get asksNumber => number != null;
}

/// The business's own channels on one line, and whether customers also
/// send money to the owner's number.
class LineChannels {
  const LineChannels({
    this.numbers = const {},
    this.notOurs = const {},
    this.pochiSpaceId,
    this.customersToNumber = false,
  });

  factory LineChannels.fromJson(Map<String, Object?> json) {
    final numbers = json['numbers'];
    final not = json['notOurs'];
    return LineChannels(
      numbers: {
        if (numbers is Map)
          for (final MapEntry(:key, :value) in numbers.entries)
            if (key is String && value is String) key: value,
      },
      notOurs: {
        if (not is List)
          for (final n in not)
            if (n is String) n,
      },
      pochiSpaceId: json['pochi'] is String ? json['pochi']! as String : null,
      customersToNumber: json['customersToNumber'] == true,
    );
  }

  /// Named tills and paybills ([keyOf]) to the space their money goes to.
  final Map<String, String> numbers;

  /// Tills and paybills the owner said are not the business's: asked once.
  final Set<String> notOurs;

  /// The space the owner's Pochi on this line belongs to, once named.
  final String? pochiSpaceId;

  /// "Customers also send money to my number": money sent to the owner's
  /// number is asked about, rather than personal (owner's decision 15).
  final bool customersToNumber;

  Map<String, Object?> toJson() => {
    'numbers': numbers,
    'notOurs': notOurs.toList()..sort(),
    'pochi': ?pochiSpaceId,
    'customersToNumber': customersToNumber,
  };

  /// How a till or paybill is kept: `till:123456`, `paybill:400200`.
  String keyOf(ChannelKind kind, String number) =>
      '${kind == ChannelKind.paybill ? 'paybill' : 'till'}:${number.trim()}';

  /// The space [number]'s money goes to, when it is named.
  String? spaceOf(ChannelKind kind, String number) =>
      numbers[keyOf(kind, number)];

  /// The named tills and paybills, as `(kind, number)`.
  List<(ChannelKind, String)> get named => [
    for (final key in numbers.keys)
      (
        key.startsWith('paybill:') ? ChannelKind.paybill : ChannelKind.till,
        key.substring(key.indexOf(':') + 1),
      ),
  ];

  LineChannels copyWith({
    Map<String, String>? numbers,
    Set<String>? notOurs,
    bool? customersToNumber,
  }) => LineChannels(
    numbers: numbers ?? this.numbers,
    notOurs: notOurs ?? this.notOurs,
    pochiSpaceId: pochiSpaceId,
    customersToNumber: customersToNumber ?? this.customersToNumber,
  );

  /// With [number] named as [spaceId]'s.
  LineChannels withNumber(ChannelKind kind, String number, String spaceId) =>
      copyWith(
        numbers: {...numbers, keyOf(kind, number): spaceId},
        notOurs: {...notOurs}..remove(keyOf(kind, number)),
      );

  /// With [number] said not to be the business's.
  LineChannels withNotOurs(ChannelKind kind, String number) =>
      copyWith(notOurs: {...notOurs, keyOf(kind, number)});
}

/// A till or paybill read from how the owner already tells customers to pay,
/// such as the invoices' "Till 123456" or "Paybill 400200 account 12":
/// the kind and the number, or null.
(ChannelKind, String)? channelFromPayLine(String? line) {
  if (line == null) return null;
  final match = RegExp(
    r'(till|buy goods|paybill|pay bill)\D{0,12}(\d{5,7})',
    caseSensitive: false,
  ).firstMatch(line);
  if (match == null) return null;
  final word = match.group(1)!.toLowerCase();
  return (
    word.startsWith('pay') ? ChannelKind.paybill : ChannelKind.till,
    match.group(2)!,
  );
}
