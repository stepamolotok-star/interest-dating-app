// Снимки экранов демо-режима с настоящими шрифтами.
// Запуск: flutter test test_screens  → картинки в build/screenshots/.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/app.dart';
import 'package:svoi/code_autofill.dart';
import 'package:svoi/state.dart';

Future<void> _loadFonts() async {
  final manrope = FontLoader('Manrope');
  for (final w in [400, 600, 700, 800]) {
    manrope.addFont(rootBundle.load('assets/fonts/Manrope-$w.ttf'));
  }
  await manrope.load();
  await (FontLoader('Unbounded')..addFont(rootBundle.load('assets/fonts/Unbounded-700.ttf'))).load();
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter';
  final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  await (FontLoader(
    'MaterialIcons',
  )..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())))).load();
}

void main() {
  const root = Key('root');

  testWidgets('снимки экранов', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    Directory('build/screenshots').createSync(recursive: true);

    Future<void> shot(String name) async {
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(root));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('build/screenshots/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    Future<void> tap(Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    final state = AppState(DemoApi(), autofill: const NoCodeAutofill());
    await tester.pumpWidget(
      RepaintBoundary(
        key: root,
        child: SvoiApp(state: state..start()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('phone')), '9123456789');
    await shot('01_phone');
    await tap(find.text('Получить звонок'));
    await tester.enterText(find.byKey(const Key('code')), '12');
    await shot('02_code');
    await tester.enterText(find.byKey(const Key('code')), DemoApi.demoCode);
    await tester.pumpAndSettle();

    await tap(find.text('Дальше'));
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await shot('02b_about_errors');
    await tester.enterText(find.byKey(const Key('name')), 'Аня');
    await tester.enterText(find.byKey(const Key('birth')), '01021995');
    await tap(find.text('Женщина'));
    await tap(find.byKey(const Key('city')));
    // Одноимённые города различаются регионом.
    await tester.enterText(find.byKey(const Key('city-search')), 'Кировск');
    await tester.pumpAndSettle();
    await shot('03a_city_same_name');
    await tester.enterText(find.byKey(const Key('city-search')), 'Чита');
    await tester.pumpAndSettle();
    await tap(find.byKey(const Key('city-2d9abaa6-85a6-4f1f-a1bd-14b76ec17d9c')));
    await tap(find.byKey(const Key('terms')));
    await tap(find.byKey(const Key('personal_data')));
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, 300));
    await shot('03_about');
    await tap(find.text('Дальше'));

    await tap(find.byKey(const Key('goal-family')));
    await tap(find.byKey(const Key('goal-friendship')));
    await tap(find.byKey(const Key('goal-hobby')));
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, 500));
    await shot('04_goals');
    await tap(find.text('Дальше'));

    for (final id in [
      'fitness.strength.yoga',
      'society.inner.meditation',
      'society.inner.self_development',
    ]) {
      await tester.enterText(
        find.byKey(const Key('interest-search')),
        id.split('.').last == 'yoga'
            ? 'йога'
            : id.endsWith('meditation')
            ? 'медитац'
            : 'саморазв',
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tap(find.byKey(Key('result-$id')));
      if (id.endsWith('yoga')) {
        await tap(find.text('Увлечён всерьёз'));
        await tap(find.text('Ищу партнёра'));
        await shot('06_interest_sheet');
      }
      await tap(find.text('Добавить'));
    }
    // «Слушаю рок» — без степени увлечённости.
    await tester.enterText(find.byKey(const Key('interest-search')), 'рок');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tap(find.byKey(const Key('result-music.listen.rock')));
    await shot('06a_interest_sheet_fan');
    await tap(find.text('Отмена'));
    await tester.enterText(find.byKey(const Key('interest-search')), '');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    final list = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Общество и духовность'), 300, scrollable: list);
    await tap(find.text('Общество и духовность'));
    await tester.scrollUntilVisible(find.text('Духовные практики'), 200, scrollable: list);
    await shot('05_interests');
    await tap(find.text('Дальше'));

    await shot('06b_profile_step');
    await tester.enterText(
      find.byKey(const Key('about')),
      'Йога по утрам, по выходным — походы и костёр. Ищу компанию на Кодар.',
    );
    final step = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.byKey(const Key('habit-smoking-no')), 250, scrollable: step);
    await tap(find.byKey(const Key('habit-smoking-no')));
    await tap(find.byKey(const Key('habit-sport-regular')));
    await shot('06c_profile_step_habits');
    await tap(find.text('Готово — к людям'));

    await shot('07_feed');
    await tap(find.byKey(const Key('more-interests')));
    await shot('07b_feed_all_interests');
    await tap(find.byKey(const Key('like')));
    await shot('08_match');
    await tap(find.byKey(const Key('write')));
    await shot('09_chat_hello');
    await tap(find.byKey(const Key('use-hint')));
    await tap(find.byKey(const Key('send')));
    await tester.pump(DemoApi.replyDelay + const Duration(seconds: 3));
    await tester.enterText(
      find.byKey(const Key('message')),
      'С универа! Давай как-нибудь сходим на занятие вместе?',
    );
    await tester.pump();
    await tap(find.byKey(const Key('send')));
    await shot('10_chat');
    await tap(find.byKey(const Key('chat-menu')));
    await tap(find.text('Пожаловаться'));
    await tap(find.byKey(const Key('reason-minor')));
    await shot('11_report');
    Navigator.of(tester.element(find.text('Отправить жалобу'))).pop(); // закрыть, не отправляя
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    await shot('12_chats');

    // Ещё одно совпадение — чтобы во вкладке «Совпадения» было кого показать.
    await tap(find.text('Лента'));
    await tap(find.byKey(const Key('skip')));
    await tap(find.byKey(const Key('like')));
    await tap(find.byKey(const Key('like')));
    await tap(find.text('Смотреть дальше'));
    await tap(find.text('Взаимно'));
    await shot('13_matches');
    await tap(find.text('Профиль'));
    await shot('14_profile');

    await tap(find.byKey(const Key('block-prompts')));
    await tap(find.byKey(const Key('add-prompt')));
    await tap(find.text('Чему могу научить'));
    await tester.enterText(
      find.byKey(const Key('prompt-answer')),
      'Стоять на голове и ставить палатку под дождём',
    );
    await tap(find.text('Готово'));
    await shot('14b_profile_block');
    await tap(find.text('Сохранить'));
    await tester.pump(const Duration(seconds: 5));
    await shot('14c_profile_filled');
    final profile = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.byKey(const Key('photos-after-match')), 300, scrollable: profile);
    await tester.drag(profile, const Offset(0, -300));
    await shot('14d_profile_privacy');
    await tester.drag(profile, const Offset(0, 5000));
    await tester.pumpAndSettle();
    await tap(find.byKey(const Key('preview')));
    await shot('14e_preview');
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();

    await tap(find.text('Рядом'));
    await shot('15_nearby_intro');
    await tap(find.byKey(const Key('become-visible')));
    await tap(find.byKey(const Key('hours-3')));
    await shot('16_visibility');
    await tap(find.text('Включить видимость'));
    await shot('17_radar');
    await tap(find.byKey(const Key('nearby-settings')));
    await tap(find.byKey(const Key('add-zone')));
    await tap(find.text('Сохранить зону'));
    await shot('18_nearby_settings');

    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    await tap(find.text('Лента'));
    await tap(find.byKey(const Key('filters')));
    await tap(find.byKey(const Key('gender-male')));
    await tap(find.byKey(const Key('min-shared-2')));
    final filters = find.byType(Scrollable).first;
    await tester.drag(filters, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await shot('19_filters');
    await tester.scrollUntilVisible(find.byKey(const Key('habit-smoking-no')), 250, scrollable: filters);
    await tap(find.byKey(const Key('habit-smoking-no')));
    await tap(find.byKey(const Key('required-Привычки')));
    await tester.drag(filters, const Offset(0, 180));
    await tester.pumpAndSettle();
    await shot('20_filters_more');
  });
}
