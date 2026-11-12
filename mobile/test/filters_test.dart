import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:svoi/app.dart';
import 'package:svoi/models.dart';

import 'helpers.dart';

void main() {
  test('фильтры: пустые не отправляются, заданные — в формате сервера', () {
    expect(GoalPrefs().toJson(), {'age': {}, 'height': {}, 'weight': {}});
    final p = GoalPrefs(
      age: const IntRange(25, 35),
      genders: ['female'],
      habits: {
        'smoking': ['no'],
        'pets': [],
      },
      habitsRequired: true,
    );
    expect(p.toJson(), {
      'age': {'min': 25, 'max': 35},
      'genders': ['female'],
      'height': {},
      'weight': {},
      'habits': {
        'smoking': ['no'],
      },
      'habits_required': true,
    });
    expect(GoalPrefs.fromJson(p.toJson()).count, 3);
  });

  testWidgets('фильтр по полу и «обязательно» в ленте', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    Future<void> tap(Finder f) async {
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

    await tap(find.byKey(const Key('filters')));
    expect(find.text('Фильтры: Дружба'), findsOneWidget);
    // Рост и вес — только в романтических целях.
    expect(find.text('Рост'), findsNothing);
    await tap(find.byKey(const Key('gender-male')));
    // «Обязательно» неактивно, пока критерий не задан.
    final dietRequired = find.byKey(const Key('required-Питание'));
    await tester.scrollUntilVisible(dietRequired, 250, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<Switch>(dietRequired).onChanged, isNull);
    await tap(find.byKey(const Key('diet-vegetarian')));
    await tap(dietRequired);
    await tester.tap(find.text('Показать людей'));
    await tester.pumpAndSettle();

    final saved = await state.api.prefs('friendship');
    expect(saved.genders, ['male']);
    expect(saved.diets, ['vegetarian']);
    expect(saved.dietRequired, isTrue);
    // Значок на кнопке фильтров и только мужчины в демо-ленте.
    expect(find.text('2'), findsOneWidget);
    // Демо-API делает настоящие паузы, поэтому вызываем его вне поддельного времени теста.
    final cards = (await tester.runAsync(() => state.api.feed('friendship')))!;
    expect(cards.map((c) => c.about), everyElement(isNot(contains('Студентка'))));
  });
}
