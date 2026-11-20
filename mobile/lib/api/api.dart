import 'dart:typed_data';

import 'package:material_ui/material_ui.dart' show ImageProvider;

import '../models.dart';

/// Ошибка API с текстом, который можно показать человеку.
class ApiException implements Exception {
  const ApiException(
    this.status,
    this.message, {
    this.field = '',
    this.retryAfter = 0,
    this.blocked = false,
    this.until,
  });

  final int status;
  final String message;

  /// Поле формы, к которому относится ошибка (если есть).
  final String field;

  /// Через сколько секунд можно повторить (для 429).
  final int retryAfter;

  /// Аккаунт заблокирован модератором; [until] — до какого момента (null — навсегда).
  final bool blocked;
  final DateTime? until;

  bool get unauthorized => status == 401;
  bool get notRegistered => status == 403 && !blocked && message.contains('регистрац');

  @override
  String toString() => message;
}

/// Всё, что приложение просит у сервера. Есть настоящая реализация
/// (HttpApi) и демо-режим без сервера (DemoApi).
abstract class Api {
  /// Токен текущей сессии; null — не вошли.
  String? token;

  /// Событие для уведомления на телефоне. В демо — свои события (ответ собеседника,
  /// взаимный интерес позже); с сервером сюда придут push, когда подключим RuStore.
  void Function(PushEvent e)? onPush;

  /// Вызывается, когда сервер ответил «аккаунт заблокирован» на любой запрос.
  void Function(ApiException e)? onBlocked;

  /// Подготовка при запуске (демо-режим поднимает сохранённые данные).
  Future<void> init() async {}

  Future<Challenge> startAuth(String phone, {String method = 'call'});
  Future<Session> verify(String phone, String code);
  Future<void> register(Registration r);

  /// Подключённые на сервере способы входа (VK ID, Яндекс ID). Пусто — только по номеру.
  Future<List<AuthProvider>> authProviders();
  Future<OAuthStart> oauthStart(String provider);
  Future<Session> oauthFinish(String provider, {required String state, required String code, String deviceId = ''});
  Future<void> logout();
  Future<Me> me();

  Future<NotificationSettings> notificationSettings();
  Future<void> setNotificationSettings(NotificationSettings s);

  /// Токен устройства для push; при выходе — отвязать.
  Future<void> registerPushToken(String token);
  Future<void> unregisterPushToken(String token);

  /// Человек прочитал предупреждение модератора — больше не показываем.
  Future<void> ackWarning();

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

  Future<ContactsStatus> contactsStatus();

  /// Заменяет список контактов (SHA-256 номеров в hex) и включает скрытие от них.
  Future<ContactsStatus> uploadContacts(List<String> hashes);

  /// Выключает скрытие и удаляет загруженные хэши.
  Future<void> clearContacts();

  Future<ProfileFields> profile();

  /// Свои фото по порядку.
  Future<List<MyPhoto>> myPhotos();

  /// Загрузить фото (JPEG/PNG/WebP как есть; сервер сам уменьшит и уберёт метаданные).
  Future<MyPhoto> uploadPhoto(Uint8List bytes);
  Future<void> deletePhoto(String id);

  /// Новый порядок: все свои фото, первое станет главным.
  Future<void> reorderPhotos(List<String> ids);

  /// Проверка фото по селфи: состояние, выдать жест, отправить селфи.
  Future<Verification> verification();
  Future<Verification> startVerification();
  Future<Verification> submitSelfie(String id, Uint8List bytes);

  /// Картинка фото по id — своего или чужого (сервер проверит, можно ли).
  ImageProvider photo(String id);

  /// Сохраняет анкету. [grantSpecial] — человек только что дал отдельное согласие
  /// на обработку религиозных убеждений (ст. 10 152-ФЗ).
  Future<void> updateProfile(ProfileFields fields, {bool grantSpecial = false});

  /// Кто видит поле: anonymous | after_match | matching_only | hidden.
  Future<Map<String, String>> fieldVisibility();
  Future<void> setFieldVisibility(Map<String, String> changes);

  Future<GoalPrefs> prefs(String goal);
  Future<void> setPrefs(String goal, GoalPrefs prefs);

  /// Демо-режим: подсказка с кодом и фальшивые люди в ленте.
  bool get isDemo => false;
}
