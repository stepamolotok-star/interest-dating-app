import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:svoi/app.dart';

import 'helpers.dart';

/// Анкета блоками в профиле: каждый блок правится отдельно, приватность — своим разделом.
void main() {
  testWidgets('анкета по блокам, приватность и религия', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    Future<void> tap(Finder f) async {
      // Профиль длинный, а список строится лениво: сначала докручиваем до элемента.
      await reveal(tester, f);
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    Future<void> see(Finder f) async {
      await reveal(tester, f);
      expect(f, findsOneWidget);
    }

    Future<void> save() async {
      await tap(find.text('Сохранить'));
      await tester.pump(const Duration(seconds: 5)); // уходит «Сохранено»
      await tester.pumpAndSettle();
    }

    final state = await tester.runAsync(registered);
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    await tester.pumpAndSettle();
    await tap(find.text('Профиль'));

    // Пустая анкета: 0 %, у каждого блока видно, что он не заполнен.
    await see(find.text('Анкета заполнена на 0%'));
    expect(find.text('Не заполнено — добавить'), findsNWidgets(5));

    // «О себе» — только этот блок.
    await tap(find.byKey(const Key('block-about')));
    expect(find.byKey(const Key('habit-smoking-no')), findsNothing);
    await tester.enterText(find.byKey(const Key('about')), 'Хожу в походы и пеку хлеб');
    await save();
    await see(find.text('Хожу в походы и пеку хлеб'));
    await see(find.text('Анкета заполнена на 20%'));

    await tap(find.byKey(const Key('block-prompts')));
    await tap(find.byKey(const Key('add-prompt')));
    await tap(find.text('Чему могу научить'));
    await tester.enterText(find.byKey(const Key('prompt-answer')), 'Ставить палатку под дождём');
    await tap(find.text('Готово'));
    await save();

    await tap(find.byKey(const Key('block-habits')));
    await tap(find.byKey(const Key('habit-smoking-no')));
    await save();
    await see(find.text('Не курю'));

    await tap(find.byKey(const Key('block-diet')));
    await tap(find.byKey(const Key('diet-vegetarian')));
    await save();

    await tap(find.byKey(const Key('block-looks')));
    await tester.enterText(find.byKey(const Key('height')), '168');
    await save();
    await see(find.text('рост 168 см'));
    await see(find.text('Анкета заполнена'));

    // Приватность: переключатели сохраняются сразу.
    await tap(find.byKey(const Key('photos-after-match')));
    await tap(find.byKey(const Key('age-as-range')));
    expect((await state.api.fieldVisibility())['photos'], 'after_match');
    expect((await state.api.profile()).ageAsRange, isTrue);
    // Свои фото скрыты — чужие в ленте тоже под замком.
    final cards = (await tester.runAsync(() => state.api.feed('friendship')))!;
    expect(cards, everyElement(predicate<dynamic>((c) => c.photosHidden == true)));

    // Религия — только с отдельным согласием; повторное нажатие снимает выбор.
    await tap(find.byKey(const Key('block-religion')));
    await tap(find.byKey(const Key('religion-orthodox')));
    expect(find.text('Отдельное согласие'), findsOneWidget);
    await tap(find.text('Даю согласие'));
    await save();
    expect((await state.api.profile()).religion, 'orthodox');
    await tap(find.byKey(const Key('block-religion')));
    await tap(find.byKey(const Key('religion-orthodox')));
    await save();

    final saved = await state.api.profile();
    expect(saved.about, 'Хожу в походы и пеку хлеб');
    expect(saved.prompts.single.answer, 'Ставить палатку под дождём');
    expect(saved.habits, {'smoking': 'no'});
    expect(saved.diet, 'vegetarian');
    expect(saved.heightCm, 168);
    expect(saved.religion, isEmpty);

    // «Как меня видят»: своя карточка, возраст диапазоном, фото под замком.
    await tap(find.byKey(const Key('preview')));
    expect(find.text('Аня, 28–32 лет'), findsOneWidget);
    expect(find.text('Хожу в походы и пеку хлеб'), findsOneWidget);
    expect(find.text('Фото откроется, если интерес будет взаимным'), findsOneWidget);
    expect(find.text('Йога'), findsOneWidget);
  });
}
