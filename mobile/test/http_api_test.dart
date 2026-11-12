import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:svoi/api/api.dart';
import 'package:svoi/api/http_api.dart';
import 'package:svoi/models.dart';

/// Клиент говорит с сервером в том же формате, что описан в README бэкенда.
void main() {
  http.Response json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
      http.Response.bytes(
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
      client: MockClient(
        (_) async => json({'error': 'подождите перед новым кодом'}, 429, {'retry-after': '42'}),
      ),
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
        terms: true,
        personalData: true,
      ),
    );
    expect(body['birth_date'], '1995-02-01');
    expect(body['consents'], {'terms': true, 'personal_data': true});
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
}
