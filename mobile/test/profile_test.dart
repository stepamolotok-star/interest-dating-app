import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:svoi/app.dart';

import 'helpers.dart';

/// Анкета: о себе, ответ на вопрос, привычка, религия с отдельным согласием.
void main() {
  testWidgets('заполнить анкету и убрать религию', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    Future<void> tap(Finder f) async {
      // Анкета длинная, а список строится лениво: сначала докручиваем до элемента.
      if (f.evaluate().isEmpty) {
        await tester.scrollUntilVisible(f, 250, scrollable: find.byType(Scrollable).first);
      }
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    final state = await tester.runAsync(registered);
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    await tester.pumpAndSettle();
    await tap(find.text('Профиль'));
    await tap(find.byKey(const Key('fill-profile')));

    await tester.enterText(find.byKey(const Key('about')), 'Хожу в походы и пеку хлеб');
    await tap(find.byKey(const Key('add-prompt')));
    await tap(find.text('Чему могу научить'));
    await tester.enterText(find.byKey(const Key('prompt-answer')), 'Ставить палатку под дождём');
    await tap(find.text('Готово'));
    await tap(find.byKey(const Key('habit-smoking-no')));
    await tap(find.byKey(const Key('diet-vegetarian')));
    await tester.enterText(find.byKey(const Key('height')), '168');

    // Религия — только с отдельным согласием.
    await tap(find.byKey(const Key('religion-orthodox')));
    expect(find.text('Отдельное согласие'), findsOneWidget);
    await tap(find.text('Даю согласие'));
    await tap(find.text('Сохранить'));

    expect(find.text('Хожу в походы и пеку хлеб'), findsOneWidget);
    expect(find.text('Ставить палатку под дождём'), findsOneWidget);
    final saved = await state.api.profile();
    expect(saved.habits, {'smoking': 'no'});
    expect(saved.diet, 'vegetarian');
    expect(saved.heightCm, 168);
    expect(saved.religion, 'orthodox');

    // Убрать религию: повторное нажатие снимает выбор.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tap(find.text('Изменить').first);
    await tap(find.byKey(const Key('religion-orthodox')));
    await tap(find.text('Сохранить'));
    expect((await state.api.profile()).religion, isEmpty);
  });
}
