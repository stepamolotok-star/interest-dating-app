import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:svoi/api/api.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/app.dart';
import 'package:svoi/auth_browser.dart';
import 'package:svoi/state.dart';

/// Браузер, который возвращает то, что ему скажут.
class _FakeBrowser implements AuthBrowser {
  _FakeBrowser(this.reply);
  final Uri? Function(Uri url) reply;

  @override
  Future<Uri?> open(Uri url, String callbackScheme) async => reply(url);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('кнопки VK ID и Яндекс ID с пояснением, вход ведёт к регистрации', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final state = AppState(DemoApi());
    await tester.pumpWidget(SvoiApp(state: state..start()));
    await tester.pumpAndSettle();

    expect(find.text('Войти через VK ID'), findsOneWidget);
    expect(find.text('Войти через Яндекс ID'), findsOneWidget);
    expect(find.textContaining('нужен только номер телефона'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('login-vk')));
    await tester.tap(find.byKey(const Key('login-vk')));
    await tester.pumpAndSettle();
    expect(state.stage, Stage.about);
  });

  group('разбор возврата от провайдера', () {
    Future<AppState> withBrowser(Uri? Function(Uri) reply) async {
      final state = AppState(DemoApi(), browser: _FakeBrowser(reply));
      await state.start();
      return state;
    }

    test('VK ID: параметры в payload', () async {
      final state = await withBrowser(
        (url) => Uri.parse(
          'vk1://vk.ru/blank.html?payload=${Uri.encodeComponent(jsonEncode({'code': 'c', 'state': url.queryParameters['state'], 'device_id': 'd'}))}',
        ),
      );
      expect(await state.loginWith('vk'), isTrue);
      expect(state.stage, Stage.about);
    });

    test('окно закрыли — ничего не происходит', () async {
      final state = await withBrowser((_) => null);
      expect(await state.loginWith('yandex'), isFalse);
      expect(state.stage, Stage.phone);
    });

    test('чужой state — отказ', () async {
      final state = await withBrowser((_) => Uri.parse('ru.svoi://oauth?code=c&state=подмена'));
      expect(() => state.loginWith('yandex'), throwsA(isA<ApiException>()));
    });

    test('отказ у провайдера — понятная ошибка', () async {
      final state = await withBrowser((url) => Uri.parse('ru.svoi://oauth?error=access_denied'));
      expect(
        () => state.loginWith('yandex'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('войдите по звонку'))),
      );
    });
  });
}
