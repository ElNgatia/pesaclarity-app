// The M-Pesa family of accounts (decision 0026): the wallet at its head,
// and the accounts money moves to and from through it. M-Shwari, Ziidi and
// Etica MMF are savings products the app keeps (`savings_product.dart`);
// Pochi la Biashara, the person's own business wallet, is read from its
// own messages.

/// The account reference of the person's own Pochi la Biashara: M-Pesa's
/// messages for money paid into it print "New Pochi balance", which the
/// readers keep as its own account, `Pochi`.
const pochiReference = 'pochi';

/// What a Pochi la Biashara account is called.
const pochiName = 'Pochi la Biashara';

/// Whether [reference] is a Pochi la Biashara account's.
bool isPochiReference(String? reference) => reference == pochiReference;

/// Whether [ownAccount], the own account a message rule read, is the
/// person's Pochi la Biashara.
bool isPochiOwnAccount(String? ownAccount) =>
    ownAccount?.trim().toLowerCase() == pochiReference;

/// The account reference a message's [ownAccount] keys: [pochiReference]
/// for Pochi la Biashara, otherwise the number as printed.
String? ownAccountReference(String? ownAccount) =>
    isPochiOwnAccount(ownAccount) ? pochiReference : ownAccount;

/// Why a message into the person's Pochi la Biashara waits in the review
/// inbox, the one place its text is kept: Pochi is not an account in the
/// space that read it yet. It waits there, never income, spending or
/// M-Pesa's money, until the person answers "You have Pochi la Biashara.
/// Add it?" (decision 0026 item 5) and is read onto its account on Add.
const pochiAskReason = 'mpesa_pochi_not_added';

/// The setting that keeps "Not now" about Pochi la Biashara in a space, so
/// it is not asked again there.
const pochiDeclinedKey = 'mpesa.pochiDeclined';
