import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesaclarity/src/core/time/clock.dart';
import 'package:pesaclarity/src/data/database/database_providers.dart';
import 'package:pesaclarity/src/domain/sharing/share_model.dart';
import 'package:pesaclarity/src/domain/spaces/space.dart';
import 'package:pesaclarity/src/features/sharing/application/share_providers.dart';
import 'package:pesaclarity/src/features/sharing/presentation/share_screens.dart';
import 'package:pesaclarity/src/features/spaces/application/spaces_providers.dart';
import 'package:pesaclarity/src/theme/app_theme.dart';

import '../../helpers/fake_app_lock.dart';
import '../../helpers/share_phones.dart';
import '../../helpers/test_app.dart';

const _kilimani = Space(
  id: 'kilimani',
  name: 'Home at Kilimani',
  kind: SpaceKind.household,
);

class _Picker implements ShareFilePicker {
  _Picker(this.file);

  final List<int> file;

  @override
  Future<(String, List<int>)?> pick() async => ('kilimani-22nov.pcshare', file);
}

Future<void> _pump(
  WidgetTester tester,
  Phone phone,
  Widget home, {
  Space space = _kilimani,
  List<int>? file,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(phone.db),
        clockProvider.overrideWithValue(
          () => DateTime.fromMillisecondsSinceEpoch(phone.now),
        ),
        activeSpaceProvider.overrideWithValue(space),
        shareRepositoryProvider.overrideWithValue(phone.repo),
        if (file != null)
          shareFilePickerProvider.overrideWithValue(_Picker(file)),
        ...appLockOverrides(),
      ],
      child: MaterialApp(theme: AppTheme.light, home: home),
    ),
  );
  await settleFrames(tester);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Share this space lists members, the limit and the note', (
    tester,
  ) async {
    late Phone me;
    await tester.runAsync(() async => (me, _) = await kilimani());
    await _pump(tester, me, const ShareSpaceScreen(spaceId: 'kilimani'));
    expect(find.text('3 of 6'), findsOneWidget);
    expect(find.text('Jane Wairimu'), findsOneWidget);
    expect(find.text('Joined 3 Nov'), findsOneWidget);
    expect(find.text('No account · joined 9 Nov'), findsOneWidget);
    expect(find.text('Last sent to Jane · Fri 20 Nov'), findsOneWidget);
    await scrollTo(tester, find.text(sharePrivacyNote));
    expect(find.text(sharePrivacyNote), findsOneWidget);
    expect(
      find.text('A Household holds up to 6 people, a Savings group up to 30.'),
      findsOneWidget,
    );
  });

  testWidgets('a role: Treasurer only in a chama, Remove in red', (
    tester,
  ) async {
    late Phone me;
    late ShareMember jane;
    await tester.runAsync(() async {
      (me, _) = await kilimani();
      jane = (await me.repo.members()).values.firstWhere(
        (m) => m.name == 'Jane Wairimu',
      );
    });
    await _pump(
      tester,
      me,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showRoleSheet(context, jane),
          child: const Text('Open'),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Treasurer'), findsNothing);
    final remove = tester.widget<Text>(find.text('Remove from group'));
    expect(
      remove.style!.color,
      Theme.of(tester.element(find.text('Remove from group')))
          .colorScheme
          .error,
    );
    await tester.tap(find.byKey(const Key('share-role-viewer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-role-save')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    final role = await tester.runAsync(
      () async => (await me.repo.members())[jane.id]!.role,
    );
    expect(role, ShareRole.viewer);
  });

  testWidgets('an update file: what it holds, then Apply', (tester) async {
    late Phone me;
    late List<int> file;
    await tester.runAsync(() async => (me, file) = await kilimani());
    await _pump(
      tester,
      me,
      const ShareSpaceScreen(spaceId: 'kilimani'),
      file: file,
    );
    await tester.tap(find.byKey(const Key('share-receive')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(
      find.text('From Jane: 14 new, 2 changed, 1 conflict (later wins)'),
      findsOneWidget,
    );
    expect(
      find.textContaining("Jane's is later, so 20,000 stays."),
      findsOneWidget,
    );
    await tester.runAsync(() => me.repo.apply(file));
    final payees = await tester.runAsync(me.payees);
    expect(payees, contains('Naivas'));
  });

  testWidgets('joining: the words, a name, and no account needed', (
    tester,
  ) async {
    late Phone brian;
    late String invite;
    late List<String> words;
    await tester.runAsync(() async {
      final jane = Phone('Jane Wairimu');
      await jane.repo.start(myName: 'Jane Wairimu');
      (invite, _, words) = await jane.repo.invite(
        name: 'Brian',
        role: ShareRole.member,
        spaceName: 'Home at Kilimani',
      );
      brian = Phone('Brian');
    });
    await _pump(tester, brian, JoinSpaceScreen(invite: invite));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('Join Home at Kilimani'), findsOneWidget);
    expect(find.textContaining("You don't need an account"), findsOneWidget);
    expect(find.text(words.join(' · ')), findsOneWidget);
    expect(find.text('The words match, join'), findsOneWidget);
  });
}
