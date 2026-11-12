import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'api.dart';

/// Клиент настоящего сервера (backend/).
class HttpApi extends Api {
  HttpApi(this.baseUrl, {http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  static const _timeout = Duration(seconds: 15);

  Future<dynamic> _call(String method, String path, {Object? body, Map<String, String>? query}) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final headers = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json; charset=utf-8',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    final req = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);

    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(_timeout));
    } on Exception {
      throw const ApiException(0, 'Нет связи с сервером. Проверьте интернет и попробуйте ещё раз.');
    }

    final text = utf8.decode(res.bodyBytes);
    final data = text.isEmpty ? null : jsonDecode(text);
    if (res.statusCode >= 200 && res.statusCode < 300) return data;

    final map = data is Map<String, dynamic> ? data : const <String, dynamic>{};
    throw ApiException(
      res.statusCode,
      map['error'] as String? ?? 'Что-то пошло не так, попробуйте ещё раз',
      field: map['field'] as String? ?? '',
      retryAfter: int.tryParse(res.headers['retry-after'] ?? '') ?? 0,
    );
  }

  List<Map<String, dynamic>> _items(dynamic data, [String key = 'items']) =>
      (((data as Map<String, dynamic>)[key] as List?) ?? const []).cast<Map<String, dynamic>>();

  @override
  Future<Challenge> startAuth(String phone, {String method = 'call'}) async =>
      Challenge.fromJson(await _call('POST', '/v1/auth/start', body: {'phone': phone, 'method': method}));

  @override
  Future<Session> verify(String phone, String code) async {
    final j = await _call('POST', '/v1/auth/verify', body: {'phone': phone, 'code': code});
    return Session(j['token'] as String, j['registered'] as bool? ?? false);
  }

  @override
  Future<void> register(Registration r) => _call('POST', '/v1/auth/register', body: r.toJson());

  @override
  Future<void> logout() => _call('POST', '/v1/auth/logout');

  @override
  Future<Me> me() async => Me.fromJson(await _call('GET', '/v1/me'));

  @override
  Future<List<InterestNode>> categories() async =>
      _items(await _call('GET', '/v1/interests/categories')).map(InterestNode.fromJson).toList();

  @override
  Future<List<InterestNode>> children(String id) async =>
      _items(await _call('GET', '/v1/interests/${Uri.encodeComponent(id)}/children'))
          .map(InterestNode.fromJson)
          .toList();

  @override
  Future<List<InterestNode>> searchInterests(String query) async =>
      _items(await _call('GET', '/v1/interests/search', query: {'q': query, 'limit': '20'}))
          .map(InterestNode.fromJson)
          .toList();

  @override
  Future<List<GoalSetting>> goals() async =>
      _items(await _call('GET', '/v1/me/goals'), 'goals').map(GoalSetting.fromJson).toList();

  @override
  Future<void> setGoals(List<GoalSetting> goals) =>
      _call('PUT', '/v1/me/goals', body: {'goals': goals.map((g) => g.toJson()).toList()});

  @override
  Future<List<MyInterest>> interests() async =>
      _items(await _call('GET', '/v1/me/interests')).map(MyInterest.fromJson).toList();

  @override
  Future<void> setInterests(List<MyInterest> items) =>
      _call('PUT', '/v1/me/interests', body: {'items': items.map((i) => i.toJson()).toList()});

  @override
  Future<List<FeedCard>> feed(String goal, {int limit = 20}) async =>
      _items(await _call('GET', '/v1/feed', query: {'goal': goal, 'limit': '$limit'}))
          .map(FeedCard.fromJson)
          .toList();

  @override
  Future<InterestResult> expressInterest(String userId, String goal, {String? interestId}) async =>
      InterestResult.fromJson(
        await _call('POST', '/v1/feed/$userId/interest', body: {'goal': goal, 'interest_id': ?interestId}),
      );

  @override
  Future<void> skip(String userId, String goal) =>
      _call('POST', '/v1/feed/$userId/skip', body: {'goal': goal});

  @override
  Future<List<Match>> matches() async =>
      _items(await _call('GET', '/v1/matches')).map(Match.fromJson).toList();

  @override
  Future<List<Message>> messages(String matchId, {int? before}) async => _items(
    await _call('GET', '/v1/matches/$matchId/messages', query: before == null ? null : {'before': '$before'}),
  ).map(Message.fromJson).toList();

  @override
  Future<Message> send(String matchId, String body) async =>
      Message.fromJson(await _call('POST', '/v1/matches/$matchId/messages', body: {'body': body}));

  @override
  Future<void> endMatch(String matchId) => _call('POST', '/v1/matches/$matchId/end');

  @override
  Future<void> block(String userId) => _call('POST', '/v1/users/$userId/block');

  @override
  Future<bool> report(String userId, String reason, {String comment = ''}) async {
    final j = await _call('POST', '/v1/users/$userId/report', body: {'reason': reason, 'comment': comment});
    return j['urgent'] as bool? ?? false;
  }
}
