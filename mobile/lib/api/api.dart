import '../models.dart';

/// Ошибка API с текстом, который можно показать человеку.
class ApiException implements Exception {
  const ApiException(this.status, this.message, {this.field = '', this.retryAfter = 0});

  final int status;
  final String message;

  /// Поле формы, к которому относится ошибка (если есть).
  final String field;

  /// Через сколько секунд можно повторить (для 429).
  final int retryAfter;

  bool get unauthorized => status == 401;
  bool get notRegistered => status == 403 && message.contains('регистрац');

  @override
  String toString() => message;
}

/// Всё, что приложение просит у сервера. Есть настоящая реализация
/// (HttpApi) и демо-режим без сервера (DemoApi).
abstract class Api {
  /// Токен текущей сессии; null — не вошли.
  String? token;

  Future<Challenge> startAuth(String phone, {String method = 'call'});
  Future<Session> verify(String phone, String code);
  Future<void> register(Registration r);
  Future<void> logout();
  Future<Me> me();

  Future<List<InterestNode>> categories();
  Future<List<InterestNode>> children(String id);
  Future<List<InterestNode>> searchInterests(String query);

  Future<List<GoalSetting>> goals();
  Future<void> setGoals(List<GoalSetting> goals);
  Future<List<MyInterest>> interests();
  Future<void> setInterests(List<MyInterest> items);

  Future<List<FeedCard>> feed(String goal, {int limit = 20});
  Future<InterestResult> expressInterest(String userId, String goal, {String? interestId});
  Future<void> skip(String userId, String goal);

  Future<List<Match>> matches();

  /// Сообщения от новых к старым, страницами; [before] — id самого старого из уже загруженных.
  Future<List<Message>> messages(String matchId, {int? before});
  Future<Message> send(String matchId, String body);
  Future<void> endMatch(String matchId);
  Future<void> block(String userId);

  /// Возвращает true, если жалоба срочная и модератор посмотрит её первой.
  Future<bool> report(String userId, String reason, {String comment = ''});

  Future<NearbyVisibility> visibility();
  Future<NearbyVisibility> setVisibility({
    required String mode,
    int hours = 0,
    int radiusM = 1000,
    bool verifiedOnly = false,
    bool hideFromContacts = false,
  });

  /// «Исчезнуть»: видимость выключается сразу и везде.
  Future<void> disappear();
  Future<List<Zone>> zones();
  Future<Zone> addZone(String name, double lat, double lon, int radiusM);
  Future<void> deleteZone(String id);
  Future<LocationStatus> updateLocation(double lat, double lon, {bool mocked = false});

  /// Люди рядом с общими интересами; у каждой карточки заполнено [FeedCard.distance].
  Future<List<FeedCard>> radar(String goal);

  /// Демо-режим: подсказка с кодом и фальшивые люди в ленте.
  bool get isDemo => false;
}
