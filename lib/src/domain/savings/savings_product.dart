import '../enums.dart';

/// A savings app, fund or SACCO the app knows by the name its payments
/// print, so money paid into it counts as saved in an account of the
/// person's own rather than as spending.
class SavingsProduct {
  const SavingsProduct({
    required this.id,
    required this.name,
    required this.provider,
    required this.payeeNames,
    required this.paidThrough,
    this.moneyBackNames,
    this.type = AccountType.moneyMarket,
    this.currency = 'KES',
    this.keptOnItsOwn = false,
    this.inMpesaFamily = false,
    this.invested = false,
    this.goalsByCode = true,
    this.balanceInMessages = false,
    this.institutionId,
  });

  /// Kept on the account (`Accounts.product`), so it is never renamed.
  final String id;

  /// What people call it, and the account's first name.
  final String name;

  /// Who holds the money.
  final String provider;

  /// The names paying in prints, as [savingsPayeeKey] reads them. A printed
  /// name fits when its key is one of these, or starts with one and a space.
  final List<String> payeeNames;

  /// The names money coming back prints; [payeeNames] when not given.
  final List<String>? moneyBackNames;

  /// How money gets there, as the person knows it.
  final String paidThrough;

  /// The kind of account it is: one that holds savings.
  final AccountType type;
  final String currency;

  /// Kept without asking, from its first payment (decision 0026): an
  /// M-Pesa product, or a fund whose own messages are read. A savings app
  /// such as Chumz is asked about first (0028), as its paybill may serve
  /// other products.
  final bool keptOnItsOwn;

  /// One of the M-Pesa family of accounts (decision 0026), shown under
  /// M-Pesa in My accounts rather than as a savings app.
  final bool inMpesaFamily;

  /// Money invested, such as a money market fund, rather than saved. What
  /// it earns is its returns.
  final bool invested;

  /// Whether each account code its payments carry is a goal of its own,
  /// as in Chumz. Otherwise it holds one balance.
  final bool goalsByCode;

  /// Whether the M-Pesa messages that move money to and from it print its
  /// balance, as M-Shwari's do. That balance then sets the account's.
  final bool balanceInMessages;

  /// The institution whose own messages are about this account, such as
  /// `etica`: its account is the one those messages land on.
  final String? institutionId;

  /// Whether paying in to [printed] is paying into this product.
  bool takesPayIn(String? printed) => _fits(printed, payeeNames);

  /// Whether money from [printed] is this product paying back.
  bool paysBack(String? printed) =>
      _fits(printed, moneyBackNames ?? payeeNames);

  static bool _fits(String? printed, List<String> names) {
    if (printed == null) return false;
    final key = savingsPayeeKey(printed);
    if (key.isEmpty) return false;
    return names.any((name) => key == name || key.startsWith('$name '));
  }
}

/// Chumz: a goal-saving app whose money Nabo Capital holds. People pay in
/// through Nabo Capital's M-Pesa paybill, with one account code per goal.
const chumz = SavingsProduct(
  id: 'chumz',
  name: 'Chumz',
  provider: 'Nabo Capital',
  payeeNames: ['NABO CAPITAL'],
  paidThrough: 'M-Pesa paybill NABO CAPITAL LTD',
);

/// M-Shwari savings (decision 0026): M-Pesa's messages move money to and
/// from it and print its balance.
const mshwari = SavingsProduct(
  id: 'mshwari',
  name: 'M-Shwari',
  provider: 'M-Pesa',
  payeeNames: ['M-SHWARI'],
  paidThrough: 'M-Pesa',
  keptOnItsOwn: true,
  inMpesaFamily: true,
  goalsByCode: false,
  balanceInMessages: true,
);

/// Ziidi, M-Pesa's money market fund (decision 0026). No message prints its
/// value: it follows the money in and out and what the person types.
const ziidi = SavingsProduct(
  id: 'ziidi',
  name: 'Ziidi',
  provider: 'M-Pesa',
  payeeNames: ['ZIIDI'],
  paidThrough: 'M-Pesa',
  keptOnItsOwn: true,
  inMpesaFamily: true,
  invested: true,
  goalsByCode: false,
);

/// Etica Capital's money market fund. Its own messages (the `etica` pack)
/// say when money leaves it for M-Pesa; money paid in from M-Pesa is
/// mirrored on it. No message prints its value.
const eticaMmf = SavingsProduct(
  id: 'etica',
  name: 'Etica MMF',
  provider: 'Etica Capital',
  payeeNames: ['ETICA'],
  paidThrough: 'M-Pesa',
  keptOnItsOwn: true,
  invested: true,
  goalsByCode: false,
  institutionId: 'etica',
);

/// Every savings product the app knows. Another savings app, fund or SACCO
/// is one more entry.
const savingsProducts = <SavingsProduct>[chumz, mshwari, ziidi, eticaMmf];

/// The product whose own messages [institutionId]'s are, such as Etica
/// MMF for `etica`; null for any other institution.
SavingsProduct? savingsProductOfInstitution(
  String? institutionId, {
  List<SavingsProduct> products = savingsProducts,
}) {
  if (institutionId == null) return null;
  for (final product in products) {
    if (product.institutionId == institutionId) return product;
  }
  return null;
}

/// The M-Shwari balance an M-Pesa message moving money to or from it
/// prints ("New M-Shwari saving account balance is Ksh2,000.00", "M-Shwari
/// balance is Ksh1,000.00"), in minor units; null when it prints none.
/// The message readers read M-Pesa's balance only.
int? mshwariBalanceIn(String body) {
  final match = RegExp(
    r'M-Shwari\s+(?:saving\s+account\s+)?balance\s+is\s+Ksh\s*([\d,]+)(?:\.(\d{2}))?',
    caseSensitive: false,
  ).firstMatch(body);
  if (match == null) return null;
  final major = int.tryParse(match.group(1)!.replaceAll(',', ''));
  if (major == null) return null;
  return major * 100 + int.parse(match.group(2) ?? '0');
}

/// The product with [id] among [products]; null when it is not one of them.
SavingsProduct? savingsProductById(
  String? id, {
  List<SavingsProduct> products = savingsProducts,
}) {
  for (final product in products) {
    if (product.id == id) return product;
  }
  return null;
}

/// How M-Pesa marks the channel a business was paid or paid through.
const _channelWords = {'C2B', 'B2C', 'B2B'};

/// [printed], a business name as a message or statement prints it, in the
/// form products are matched by: upper case, single spaces, no dots at the
/// end and no channel word after the name, so `Nabo Capital Ltd C2B.` reads
/// `NABO CAPITAL LTD`.
String savingsPayeeKey(String printed) {
  final words = printed
      .toUpperCase()
      .replaceAll(RegExp(r'[.\s]+$'), '')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.length > 1 && _channelWords.contains(words.last)) {
    words.removeLast();
  }
  return words.join(' ').replaceAll(RegExp(r'\.+$'), '');
}

/// Money moving between one of the person's accounts and a savings product.
sealed class SavingsMove {
  const SavingsMove(this.product);

  final SavingsProduct product;
}

/// Money paid into [product] under the account [code], which is empty when
/// the payment names none.
class SavingsPayIn extends SavingsMove {
  const SavingsPayIn(super.product, this.code);

  final String code;
}

/// Money [product] paid back.
class SavingsMoneyBack extends SavingsMove {
  const SavingsMoneyBack(super.product);
}

/// What a transaction on one of the person's day-to-day accounts is to a
/// savings product in [products], or null when it has nothing to do with
/// one.
///
/// Paying a paybill whose name a product takes is paying in, under the
/// account code the payment gives (the text after `#` in a paybill's
/// [counterpartyValue], as `PayeeIdentifier.paybill` writes it). Money
/// received from a name a product pays back under is money back. How money
/// back is worded is not confirmed yet, so only [SavingsProduct] says which
/// names count: a transaction this does not recognise is left as it is.
SavingsMove? savingsMoveOf({
  required TransactionKind? kind,
  required TransactionDirection direction,
  PayeeIdentifierKind? counterpartyKind,
  String? counterpartyValue,
  String? counterpartyName,
  List<SavingsProduct> products = savingsProducts,
}) {
  if (kind == TransactionKind.paybill &&
      direction == TransactionDirection.outflow) {
    final paybill = counterpartyKind == PayeeIdentifierKind.paybill
        ? counterpartyValue
        : null;
    final at = paybill?.indexOf('#') ?? -1;
    final business = at < 0 ? paybill : paybill!.substring(0, at);
    final code = at < 0 ? '' : paybill!.substring(at + 1);
    for (final product in products) {
      if (product.takesPayIn(counterpartyName) ||
          product.takesPayIn(business)) {
        return SavingsPayIn(product, code);
      }
    }
    return null;
  }
  // Older readers read money into an M-Pesa product as a plain send
  // ("sent to ZIIDI"); a product the app keeps on its own takes it too.
  if (kind == TransactionKind.sent &&
      direction == TransactionDirection.outflow) {
    for (final product in products) {
      if (product.keptOnItsOwn && product.takesPayIn(counterpartyName)) {
        return SavingsPayIn(product, '');
      }
    }
    return null;
  }
  if (kind == TransactionKind.received &&
      direction == TransactionDirection.inflow) {
    for (final product in products) {
      if (product.paysBack(counterpartyName)) return SavingsMoneyBack(product);
    }
  }
  return null;
}
