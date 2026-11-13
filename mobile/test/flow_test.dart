import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/app.dart';
import 'package:svoi/state.dart';

/// Весь путь нового человека в демо-режиме: телефон → код → о себе → цели →
/// интересы → лента → взаимный интерес → профиль.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> tapText(WidgetTester tester, String text) async {
    final f = find.text(text);
    await tester.ensureVisible(f);
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(Key(key));
    await tester.ensureVisible(f);
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  testWidgets('регистрация и первое совпадение', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final state = AppState(DemoApi());
    await tester.pumpWidget(SvoiApp(state: state..start()));
    await tester.pumpAndSettle();

    // Телефон: кнопка неактивна, пока номер неполный.
    expect(find.text('Найди своих людей по интересам'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('phone')), '912345');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Получить звонок')).onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const Key('phone')), '89123456789');
    await tester.pump();
    expect(find.text('912 345-67-89'), findsOneWidget);
    await tapText(tester, 'Получить звонок');

    // Код: неверный — ошибка, верный — дальше сам, без кнопки.
    expect(find.text('Сейчас позвоним'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('code')), '0000');
    await tester.pumpAndSettle();
    expect(find.text('Неверный код'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('code')), DemoApi.demoCode);
    await tester.pumpAndSettle();

    // О себе: младше 18 нельзя, два согласия отдельно.
    expect(find.text('О себе'), findsOneWidget);
    // «Дальше» на пустой форме подсвечивает всё, что нужно заполнить.
    await tapText(tester, 'Дальше');
    for (final error in [
      'Напишите имя — хотя бы 2 буквы',
      'Введите дату полностью: ДД.ММ.ГГГГ',
      'Выберите пол',
      'Выберите город из списка',
      'Без этих двух согласий зарегистрироваться нельзя',
    ]) {
      expect(find.text(error), findsOneWidget, reason: error);
    }
    await tester.enterText(find.byKey(const Key('name')), 'Аня');
    await tester.enterText(find.byKey(const Key('birth')), '01012015');
    await tester.pump();
    expect(find.text('Приложение только для тех, кому есть 18'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('birth')), '01021995');
    await tester.pump();
    expect(find.text('01.02.1995'), findsOneWidget);
    await tapText(tester, 'Женщина');
    await tapKey(tester, 'city');
    await tester.enterText(find.byKey(const Key('city-search')), 'Чита');
    await tester.pumpAndSettle();
    await tapKey(tester, 'city-2d9abaa6-85a6-4f1f-a1bd-14b76ec17d9c');
    expect(find.text('Чита, Забайкальский край'), findsOneWidget);
    await tapKey(tester, 'terms');
    // Без согласия на обработку данных дальше нельзя — и видно, почему.
    await tapText(tester, 'Дальше');
    expect(find.text('О себе'), findsOneWidget);
    expect(find.text('Без этих двух согласий зарегистрироваться нельзя'), findsOneWidget);
    await tapKey(tester, 'personal_data');
    await tapText(tester, 'Дальше');

    // Цели: «Без обязательств» закрыта, пока возраст не подтверждён.
    expect(find.text('Кого вы ищете?'), findsOneWidget);
    await tapKey(tester, 'goal-casual');
    expect(find.textContaining('подтвердить возраст'), findsWidgets);
    await tester.pump(const Duration(seconds: 5)); // подсказка уходит и не закрывает кнопку
    await tester.pumpAndSettle();
    await tapKey(tester, 'goal-friendship');
    await tapKey(tester, 'goal-hobby');
    await tapText(tester, 'Дальше');

    // Интересы: поиск по каталогу, минимум три.
    expect(find.text('Ваши интересы'), findsOneWidget);
    expect(find.text('Выберите ещё 3'), findsOneWidget);
    for (final (query, id) in const [
      ('йога', 'fitness.strength.yoga'),
      ('медитац', 'society.inner.meditation'),
      ('саморазв', 'society.inner.self_development'),
    ]) {
      await tester.enterText(find.byKey(const Key('interest-search')), query);
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tapKey(tester, 'result-$id');
      // Сразу после выбора — уровень и «ищу партнёра».
      expect(find.text('Насколько увлечены'), findsOneWidget);
      if (id == 'fitness.strength.yoga') {
        await tapText(tester, 'Профи');
        await tapText(tester, 'Ищу партнёра');
      }
      await tapText(tester, 'Добавить');
    }
    // Уже выбранный интерес открывает те же настройки, где его можно убрать.
    await tapKey(tester, 'chip-society.inner.self_development');
    expect(find.text('Убрать'), findsOneWidget);
    await tapText(tester, 'Готово');
    await tapText(tester, 'Готово — к людям');

    // Лента: анонимная карточка с объяснением совпадения.
    expect(find.text('Свои'), findsOneWidget);
    expect(find.textContaining('общих интерес'), findsOneWidget);
    // Имя и возраст видны сразу, фото у Марины открыто — замка нет.
    expect(find.text('Марина, 27 лет'), findsOneWidget);
    expect(find.text('Фото откроется, если интерес будет взаимным'), findsNothing);
    // Точный возраст и остальные интересы по нажатию на «ещё N».
    expect(find.text('Походы'), findsNothing);
    await tapKey(tester, 'more-interests');
    expect(find.text('Походы'), findsOneWidget);
    await tapKey(tester, 'like');

    // В демо первый интерес взаимный.
    expect(find.text('Это взаимно!'), findsOneWidget);
    expect(find.textContaining('Спросите, как началось увлечение'), findsOneWidget);
    await tapKey(tester, 'write');

    // Переписка: подсказка для первого сообщения, контакты в первом сообщении нельзя.
    expect(find.text('Марина, 27'), findsWidgets);
    await tester.enterText(find.byKey(const Key('message')), 'Привет, пиши в телегу');
    await tester.pump();
    await tester.pump();
    await tapKey(tester, 'send');
    expect(find.textContaining('нельзя оставлять ссылки и контакты'), findsOneWidget);
    await tapKey(tester, 'use-hint');
    expect(find.textContaining('У нас общий интерес'), findsWidgets);
    await tapKey(tester, 'send');
    expect(find.textContaining('С чего у тебя всё началось?'), findsOneWidget);

    // Собеседник в демо отвечает, ответ приходит при следующем опросе.
    await tester.pump(DemoApi.replyDelay + const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('могу говорить часами'), findsOneWidget);

    // Назад — переписка в «Чатах», а «Совпадения» пусты.
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(find.text('Марина'), findsOneWidget);
    expect(find.textContaining('могу говорить часами'), findsOneWidget);
    await tapText(tester, 'Взаимно');
    expect(find.text('Новых совпадений нет'), findsOneWidget);

    // Жалоба «несовершеннолетний» — срочная, с блокировкой переписка исчезает.
    await tapText(tester, 'Чаты');
    await tapText(tester, 'Марина');
    await tapKey(tester, 'chat-menu');
    await tapText(tester, 'Пожаловаться');
    await tapKey(tester, 'reason-minor');
    await tapText(tester, 'Отправить жалобу');
    expect(find.textContaining('в первую очередь'), findsOneWidget);
    expect(find.text('Переписок пока нет'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // ждём, пока уйдёт уведомление о жалобе
    await tester.pumpAndSettle();

    // Профиль: имя, возраст, цели и интересы.
    await tapText(tester, 'Профиль');
    expect(find.textContaining('Аня, '), findsOneWidget);
    expect(find.text('Йога'), findsOneWidget);
    expect(state.interests.firstWhere((i) => i.id == 'fitness.strength.yoga').level, 'pro');
    expect(state.interests.firstWhere((i) => i.id == 'fitness.strength.yoga').seekingPartner, isTrue);

    await tester.scrollUntilVisible(find.text('Выйти'), 300, scrollable: find.byType(Scrollable).last);
    await tapText(tester, 'Выйти');
    expect(find.text('Найди своих людей по интересам'), findsOneWidget);
  });
}
