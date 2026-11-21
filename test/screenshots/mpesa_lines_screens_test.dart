// Two M-Pesa lines on one phone, for the accessibility check
// (tool/accessibility.sh): the offer in My accounts, the split sheet, My
// accounts once split, "Which line was this?", "Is this the same line?" and
// the rows on Home, each at every text size, in light and dark. Not
// marketing screenshots, so tool/screenshots.sh skips them. Made-up names
// and amounts.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/mpesa_lines_seed.dart';
import '../helpers/test_app.dart';
import 'harness.dart';

void main() {
  if (!checkAccessibility) return;

  void shot(
    String name,
    Widget Function(SeededLines) home, {
    bool split = false,
    bool iphone = false,
    Future<void> Function(WidgetTester tester)? then,
  }) => screenshot(name, (tester) async {
    final seeded = await tester.runAsync(
      () => seedLines(split: split, iphone: iphone),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: linesOverrides(seeded!),
        child: shotApp(home(seeded)),
      ),
    );
    await settleFrames(tester);
    await tester.pumpAndSettle();
    if (then != null) await then(tester);
    await snap(tester);
  });

  shot('lines-offer', myAccounts);
  shot(
    'lines-split-sheet',
    myAccounts,
    then: (tester) async {
      await tester.ensureVisible(find.byKey(const Key('lines-offer-split')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('lines-offer-split')));
      await tester.pumpAndSettle();
    },
  );
  shot('lines-after-split', myAccounts, split: true);
  shot('lines-iphone', myAccounts, split: true, iphone: true);
  shot(
    'lines-manage-sheet',
    myAccounts,
    split: true,
    then: (tester) async {
      await tester.scrollUntilVisible(
        find.byKey(const Key('mpesa-lines')),
        200,
      );
      await tester.ensureVisible(find.byKey(const Key('mpesa-lines')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mpesa-lines')));
      await tester.pumpAndSettle();
    },
  );
  shot('lines-home-rows', homeRows, split: true, iphone: true);
  shot('lines-which-line', whichLine, split: true, iphone: true);
  shot('lines-same-line', sameLine, split: true);
}
