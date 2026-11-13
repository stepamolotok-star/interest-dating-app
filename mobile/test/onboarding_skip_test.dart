import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/app.dart';
import 'package:svoi/code_autofill.dart';
import 'package:svoi/models.dart';
import 'package:svoi/state.dart';

import 'helpers.dart';

/// Интересы и анкету при регистрации можно пропустить — тогда напоминаем в ленте и профиле.
/// У «фанатских» интересов («слушаю рок») степень увлечённости не спрашиваем.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('пропустить интересы и анкету, напоминания, интерес без степени', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    Future<void> tap(Finder f) async {
      await reveal(tester, f);
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    final state = AppState(DemoApi(), autofill: const NoCodeAutofill());
    await tester.runAsync(() async {
      await state.start();
      await state.requestCode('+79123456789');
      await state.verify(DemoApi.demoCode);
      await state.register(
        Registration(
          name: 'Аня',
          birthDate: DateTime(1995, 2, 1),
          gender: 'female',
          city: 'Чита',
          cityId: '2d9abaa6-85a6-4f1f-a1bd-14b76ec17d9c',
          terms: true,
          personalData: true,
        ),
      );
      await state.saveGoals(['friendship']);
    });
    await tester.pumpWidget(SvoiApp(state: state));
    await tester.pumpAndSettle();
    expect(state.stage, Stage.interests);

    // Пропуск интересов — с предупреждением.
    await tap(find.byKey(const Key('skip-interests')));
    expect(find.text('Пропустить интересы?'), findsOneWidget);
    await tap(find.text('Пропустить'));
    expect(state.stage, Stage.profile);

    // Анкету тоже можно пропустить.
    await tap(find.byKey(const Key('skip-profile')));
    expect(state.stage, Stage.home);

    // В ленте — напоминание, на «Профиле» — точка и плашка.
    expect(find.text('Выберите интересы — без них подбор почти случайный'), findsOneWidget);
    await tap(find.text('Профиль'));
    await reveal(tester, find.byKey(const Key('add-interests')));
    expect(find.byKey(const Key('add-interests')), findsOneWidget);

    // «Слушаю → Рок»: без степени увлечённости, вместо «ищу партнёра» — «ищу компанию».
    await tap(find.byKey(const Key('add-interests')));
    await tester.enterText(find.byKey(const Key('interest-search')), 'рок');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tap(find.byKey(const Key('result-music.listen.rock')));
    expect(find.text('Насколько увлечены'), findsNothing);
    expect(find.text('Ищу компанию'), findsOneWidget);
    await tap(find.text('Ищу компанию'));
    await tap(find.text('Добавить'));
    // А у гитары степень есть.
    await tester.enterText(find.byKey(const Key('interest-search')), 'гитар');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tap(find.byKey(const Key('result-music.play.guitar')));
    expect(find.text('Насколько увлечены'), findsOneWidget);
    await tap(find.text('Добавить'));
    await tester.enterText(find.byKey(const Key('interest-search')), 'йога');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tap(find.byKey(const Key('result-fitness.strength.yoga')));
    await tap(find.text('Добавить'));
    await tap(find.text('Сохранить'));

    final rock = state.interests.firstWhere((i) => i.id == 'music.listen.rock');
    expect(rock.isFan, isTrue);
    expect(rock.seekingPartner, isTrue);
    expect(find.byKey(const Key('add-interests')), findsNothing);

    // Перезапуск: шаги регистрации не повторяются.
    final again = AppState(state.api);
    await tester.runAsync(again.start);
    expect(again.stage, Stage.home);
  });
}
