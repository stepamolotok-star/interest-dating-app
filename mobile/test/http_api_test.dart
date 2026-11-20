import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart' show NetworkImage;
import 'package:svoi/api/api.dart';
import 'package:svoi/api/http_api.dart';
import 'package:svoi/models.dart';

/// Клиент говорит с сервером в том же формате, что описан в README бэкенда.
void main() {
  http.Response json(Object body, [int status = 200, Map<String, String> headers = const {}]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8', ...headers},
  );

  test('лента: токен в заголовке, поля карточки разбираются', () async {
    late http.Request seen;
    final api = HttpApi(
      'https://api.test',
      client: MockClient((req) async {
        seen = req;
        return json({
          'items': [
            {
              'user_id': 'u1',
              'age_range': '25–29',
              'goal': 'hobby',
              'photo_verified': true,
              'age_verified': false,
              'score': 81,
              'explanation': '2 общих интереса: йога, бонсай',
              'shared_interests': [
                {'id': 'fitness.strength.yoga', 'name': 'Йога', 'rare': false},
                {'id': 'nature.plants.bonsai', 'name': 'Бонсай', 'rare': true},
              ],
              'other_interests_count': 4,
              'habits': {'smoking': 'no'},
              'prompts': [
                {'question': 'Идеальная суббота', 'answer': 'Горы'},
              ],
            },
          ],
        });
      }),
    )..token = 't0k';

    final cards = await api.feed('hobby', limit: 5);
    expect(seen.headers['Authorization'], 'Bearer t0k');
    expect(seen.url.queryParameters, {'goal': 'hobby', 'limit': '5'});
    expect(cards.single.shared.last.rare, isTrue);
    expect(cards.single.habits['smoking'], 'no');
    expect(cards.single.prompts.single.answer, 'Горы');
  });

  test('ошибка сервера превращается в понятный текст', () async {
    final api = HttpApi(
      'https://api.test',
      client: MockClient((_) async => json({'error': 'подождите перед новым кодом'}, 429, {'retry-after': '42'})),
    );
    await expectLater(
      api.startAuth('+79123456789'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.status, 'status', 429)
            .having((e) => e.retryAfter, 'retryAfter', 42)
            .having((e) => e.message, 'message', 'подождите перед новым кодом'),
      ),
    );
  });

  test('регистрация отправляет дату и согласия как ждёт сервер', () async {
    late Map<String, dynamic> body;
    final api = HttpApi(
      'https://api.test',
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return json({'user_id': 'u1'}, 201);
      }),
    );
    await api.register(
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
    expect(body['birth_date'], '1995-02-01');
    expect(body['consents'], {'terms': true, 'personal_data': true});
    expect(body['city_id'], '2d9abaa6-85a6-4f1f-a1bd-14b76ec17d9c');
  });

  test('интерес без отметки не шлёт interest_id', () async {
    late Map<String, dynamic> body;
    final api = HttpApi(
      'https://api.test',
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return json({'matched': true, 'match_id': 'm1'});
      }),
    );
    final res = await api.expressInterest('u2', 'friendship');
    expect(body, {'goal': 'friendship'});
    expect(res.matched, isTrue);
  });

  test('нет сети — не падаем, а говорим по-человечески', () async {
    final api = HttpApi('https://api.test', client: MockClient((_) => throw http.ClientException('offline')));
    await expectLater(api.me(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 0)));
  });

  test('«Рядом»: видимость на время и радар с интервалом расстояния', () async {
    final seen = <String>[];
    final api = HttpApi(
      'https://api.test',
      client: MockClient((req) async {
        seen.add('${req.method} ${req.url.path} ${req.body}');
        if (req.url.path == '/v1/nearby/radar') {
          return json({
            'items': [
              {'user_id': 'u3', 'goal': 'hobby', 'explanation': '1 общий интерес: эндуро', 'distance': 'до 1 км'},
            ],
          });
        }
        return json({
          'mode': 'timed',
          'visible_until': '2026-11-12T15:00:00Z',
          'radius_m': 3000,
          'verified_only': true,
          'hide_from_contacts': false,
          'active': true,
        });
      }),
    );
    final v = await api.setVisibility(mode: 'timed', hours: 3, radiusM: 3000, verifiedOnly: true);
    expect(v.active, isTrue);
    expect(v.visibleUntil!.isUtc, isFalse, reason: 'время показываем в местном поясе');
    expect(seen.single, contains('"hours":3'));
    final cards = await api.radar('hobby');
    expect(cards.single.distance, 'до 1 км');
  });

  test('блокировка: 403 с blocked и сроком, срабатывает onBlocked', () async {
    ApiException? seen;
    final api = HttpApi(
      'https://api.test',
      client: MockClient(
        (req) async => json({
          'error': 'аккаунт временно заблокирован за нарушение правил',
          'blocked': true,
          'until': '2026-11-21T10:05:00Z',
        }, 403),
      ),
    )..token = 't0k';
    api.onBlocked = (e) => seen = e;

    await expectLater(api.me(), throwsA(isA<ApiException>().having((e) => e.blocked, 'blocked', isTrue)));
    expect(seen?.until?.toUtc(), DateTime.utc(2026, 11, 21, 10, 5));
    expect(seen?.notRegistered, isFalse);
  });

  test('лимит: 429 — текст для человека', () async {
    final api = HttpApi(
      'https://api.test',
      client: MockClient((req) async => json({'error': 'слишком много сообщений подряд, передохните минуту'}, 429)),
    )..token = 't0k';
    await expectLater(
      api.send('m1', 'привет'),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('передохните'))),
    );
  });

  test('фото: файл уходит телом запроса, картинка — с токеном', () async {
    late http.Request seen;
    final api = HttpApi(
      'https://api.test',
      client: MockClient((req) async {
        seen = req;
        return json({'id': 'p1', 'position': 0});
      }),
    )..token = 't0k';
    final p = await api.uploadPhoto(Uint8List.fromList([0xFF, 0xD8, 1, 2, 3]));
    expect((p.id, p.position), ('p1', 0));
    expect(seen.method, 'POST');
    expect(seen.url.path, '/v1/me/photos');
    expect(seen.bodyBytes, [0xFF, 0xD8, 1, 2, 3]);
    expect(seen.headers['Content-Type'], 'application/octet-stream');
    final img = api.photo('p1') as NetworkImage;
    expect(img.url, 'https://api.test/v1/photos/p1');
    expect(img.headers?['Authorization'], 'Bearer t0k');
  });

  test('уведомления: настройки и токен устройства', () async {
    final calls = <String>[];
    final api = HttpApi(
      'https://api.test',
      client: MockClient((req) async {
        calls.add('${req.method} ${req.url.path} ${req.body}');
        if (req.method == 'GET') return json({'matches': true, 'messages': false, 'nearby': true, 'show_text': true});
        return http.Response('', 204);
      }),
    )..token = 't0k';
    final s = await api.notificationSettings();
    expect((s.matches, s.messages, s.showText), (true, false, true));
    await api.setNotificationSettings(s..nearby = false);
    await api.registerPushToken('dev-1');
    expect(calls[1], contains('"nearby":false'));
    expect(calls[2], 'PUT /v1/me/push-token {"token":"dev-1","provider":"rustore"}');
  });

  test('проверка по селфи: жест, отправка, статус', () async {
    final calls = <String>[];
    final api = HttpApi(
      'https://api.test',
      client: MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (req.url.path.endsWith('/selfie')) {
          expect(req.bodyBytes, [1, 2, 3]);
          return json({'status': 'pending', 'id': 'v1'});
        }
        if (req.method == 'POST') return json({'status': 'requested', 'id': 'v1', 'gesture': 'Коснитесь уха рукой'});
        return json({'status': 'rejected', 'id': 'v1', 'note': 'На селфи другой жест'});
      }),
    )..token = 't0k';
    final s = await api.startVerification();
    expect((s.status, s.id, s.gesture), ('requested', 'v1', 'Коснитесь уха рукой'));
    expect((await api.submitSelfie('v1', Uint8List.fromList([1, 2, 3]))).status, 'pending');
    final v = await api.verification();
    expect((v.status, v.note), ('rejected', 'На селфи другой жест'));
    expect(calls, ['POST /v1/me/verification', 'POST /v1/me/verification/v1/selfie', 'GET /v1/me/verification']);
  });
}
