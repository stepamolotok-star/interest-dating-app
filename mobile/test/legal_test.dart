import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/app.dart';
import 'package:svoi/legal.dart';
import 'package:svoi/screens/legal_screen.dart';
import 'package:svoi/state.dart';

import 'helpers.dart';

void main() {
  test('документы разбираются, метки подставлены, заголовки совпадают', () {
    for (final d in LegalDoc.values) {
      final md = fillLegal(File('assets/legal/${d.file}.md').readAsStringSync());
      expect(md, isNot(contains('{{')), reason: d.file);
      final blocks = parseLegal(md);
      expect((blocks.first as LegalHeading).text, d.title, reason: d.file);
      expect(blocks.whereType<LegalParagraph>(), isNotEmpty, reason: d.file);
    }
    final b = parseLegal('# Т\n\nабзац\nдальше\n\n1. **Шаг.** текст\n   - вложенный\n2. второй\n- маркер\n');
    expect((b[1] as LegalParagraph).text, 'абзац дальше');
    final step = b[2] as LegalItem;
    expect((step.number, step.text), (1, '**Шаг.** текст'));
    expect(step.sub, ['вложенный']);
    expect((b[3] as LegalItem).number, 2);
    expect((b[4] as LegalItem).number, isNull);
  });

  testWidgets('документы в профиле и «как подбираем» в ленте', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final state = await tester.runAsync(registered);
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
      await tester.pumpAndSettle();
    }

    await settle();
    await tester.tap(find.byKey(const Key('how-feed-works')));
    await settle();
    expect(find.byKey(const Key('legal-recommendations')), findsOneWidget);
    expect(find.text('1. Где применяются'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('половина оценки'),
      300,
      scrollable: find.descendant(
        of: find.byKey(const Key('legal-recommendations')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byTooltip('Назад'));
    await settle();

    await tester.tap(find.text('Профиль'));
    await settle();
    final privacy = find.byKey(const Key('doc-privacy'));
    await reveal(tester, privacy);
    await tester.ensureVisible(privacy);
    await tester.pumpAndSettle();
    await tester.tap(privacy);
    await settle();
    expect(find.byType(LegalScreen), findsOneWidget);
    expect(find.text('Политика обработки персональных данных'), findsOneWidget);
    expect(find.textContaining('[ФИО оператора]'), findsWidgets);
  });

  testWidgets('удаление аккаунта: подтверждение, вход заново, данные стёрты', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final state = await tester.runAsync(registered);
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
      await tester.pumpAndSettle();
    }

    await settle();
    await tester.tap(find.text('Профиль'));
    await settle();
    final del = find.byKey(const Key('delete-account'));
    await reveal(tester, del);
    await tester.ensureVisible(del);
    await tester.pumpAndSettle();

    // Передумали — ничего не изменилось.
    await tester.tap(del);
    await tester.pumpAndSettle();
    expect(find.text('Удалить аккаунт?'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(state.stage, Stage.home);

    await tester.tap(del);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Удалить навсегда'));
      await Future<void>.delayed(const Duration(milliseconds: 700));
    });
    await tester.pumpAndSettle();
    expect(state.stage, Stage.phone);
    expect(state.me, isNull);
    expect(state.api.token, isNull);
    // Демо стёрто: тот же номер — снова регистрация с нуля.
    final session = await tester.runAsync(() async {
      await state.api.startAuth('+79123456789');
      return state.api.verify('+79123456789', DemoApi.demoCode);
    });
    expect(session!.registered, isFalse);
    expect(state.photos, isEmpty);
  });
}
