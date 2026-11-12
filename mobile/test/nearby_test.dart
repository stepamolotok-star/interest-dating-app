import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:svoi/app.dart';
import 'package:svoi/state.dart';

import 'helpers.dart';

/// «Рядом» в демо-режиме: включить видимость, увидеть людей с интервалом расстояния,
/// исчезнуть, личная зона прячет и самого человека, и людей вокруг.
void main() {
  testWidgets('видимость, радар, «Исчезнуть» и личная зона', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    Future<void> tap(Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    final state = await tester.runAsync(registered);
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    await tester.pumpAndSettle();
    expect(state.stage, Stage.home);

    // До включения — объяснение, людей не видно.
    await tap(find.text('Рядом'));
    expect(find.text('Видят только видимые'), findsOneWidget);
    await tap(find.byKey(const Key('become-visible')));
    await tap(find.text('Включить видимость'));

    // Видимость на час: интервалы вместо точного расстояния.
    expect(find.textContaining('Вас видно · до '), findsOneWidget);
    expect(find.text('до 500 м'), findsOneWidget);
    expect(find.textContaining('общих интерес'), findsWidgets);

    // «Исчезнуть» — сразу обратно к объяснению.
    await tap(find.byKey(const Key('disappear')));
    expect(find.text('Видят только видимые'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Личная зона там, где сейчас: включаем видимость — нас не видно, и мы никого не видим.
    await tap(find.byKey(const Key('nearby-settings')));
    await tap(find.byKey(const Key('add-zone')));
    await tap(find.text('Сохранить зону'));
    expect(find.text('Дом'), findsOneWidget);
    await tap(find.byKey(const Key('visibility-switch')));
    await tap(find.byKey(const Key('hours-0')));
    await tap(find.text('Включить видимость'));
    expect(find.text('Радиус 1 км'), findsOneWidget);
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(find.text('Вы в личной зоне'), findsOneWidget);
    expect(find.text('Личная зона — вас не видно'), findsOneWidget);
    expect(find.text('до 500 м'), findsNothing);
  });

  testWidgets('«Скрыть меня от контактов» включается и выключается', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final state = await tester.runAsync(registered);
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('hide-from-contacts'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Скрыть'));
    await tester.pumpAndSettle();
    // В демо-контактах два российских мобильных и один иностранный номер.
    expect(find.textContaining('Номеров учтено: 2'), findsOneWidget);
    expect((await state.api.contactsStatus()).hide, isTrue);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect((await state.api.contactsStatus()).hide, isFalse);
  });
}
