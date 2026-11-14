import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import 'api/api.dart';

import 'dart:convert';

import 'auth_browser.dart';
import 'code_autofill.dart';
import 'contacts.dart';
import 'location.dart';
import 'models.dart';
import 'widgets/profile_blocks.dart' show profileCompletion;

/// Где человек сейчас: вход, шаги регистрации или основное приложение.
enum Stage { loading, phone, code, about, goals, interests, profile, home, blocked }

/// Состояние приложения: сессия, шаг регистрации и данные профиля.
class AppState extends ChangeNotifier {
  AppState(this.api, {LocationSource? location, ContactsSource? contacts, AuthBrowser? browser, CodeAutofill? autofill})
    : autofill = autofill ?? (api.isDemo ? const DemoCodeAutofill() : DeviceCodeAutofill()),
      browser = browser ?? (api.isDemo ? const DemoAuthBrowser() : DeviceAuthBrowser()),
      location = location ?? (api.isDemo ? const FixedLocation() : DeviceLocation()),
      contacts = contacts ?? (api.isDemo ? const DemoContacts() : DeviceContacts()) {
    api.onBlocked = _blocked;
  }

  final Api api;

  /// Автоподстановка кода из звонка или SMS. В демо «звонок» приходит сам через 2 секунды.
  final CodeAutofill autofill;

  /// Окно входа через VK ID / Яндекс ID. В демо — сразу «успешный вход».
  final AuthBrowser browser;

  /// Откуда брать геопозицию для «Рядом». В демо — фиксированная точка.
  final LocationSource location;

  /// Записная книжка для «скрыть меня от контактов». В демо — выдуманные номера.
  final ContactsSource contacts;

  static const _tokenKey = 'session_token';
  static const _themeKey = 'theme_mode';

  /// Тема: как в системе, светлая или тёмная. Хранится на телефоне.
  ThemeMode themeMode = ThemeMode.system;

  /// Читает сохранённую тему. Вызывается до первого кадра, чтобы не мигнуть светлой.
  Future<void> loadThemeMode() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_themeKey);
      themeMode = ThemeMode.values.firstWhere((m) => m.name == saved, orElse: () => ThemeMode.system);
    } catch (_) {
      themeMode = ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_themeKey, mode.name);
    } catch (_) {
      // Не сохранилось — тема всё равно сменится до перезапуска.
    }
  }

  /// Человек прошёл (или пропустил) шаги интересов и анкеты. Пока нет —
  /// при входе возвращаем к ним; потом только напоминаем.
  static const _onboardedKey = 'onboarding_done';

  Stage stage = Stage.loading;

  /// Аккаунт заблокирован модератором: причина и срок (null — навсегда).
  ApiException? block;

  /// Предупреждение модератора, которое ещё не показали. Пусто — нет.
  String warning = '';
  String phone = '';
  Challenge? challenge;
  Me? me;
  List<GoalSetting> goals = [];
  List<MyInterest> interests = [];

  /// Анкета; null — ещё не загружали или не загрузилась.
  ProfileFields? profile;

  /// Взаимные интересы; null — ещё не загружали.
  List<Match>? matches;

  /// Совпадения, где ещё никто не написал.
  List<Match> get newMatches => [
    for (final m in matches ?? const <Match>[])
      if (m.isNew) m,
  ];

  /// Начатые переписки.
  List<Match> get chats => [
    for (final m in matches ?? const <Match>[])
      if (!m.isNew) m,
  ];

  /// Цели, по которым сейчас ищем.
  List<String> get activeGoals => [
    for (final g in goals)
      if (g.active) g.goal,
  ];

  /// Меняется, когда то, что видно в ленте, зависит от новых настроек
  /// (фото после взаимности, интересы). Лента перезагружает карточки.
  int feedVersion = 0;

  void feedChanged() {
    feedVersion++;
    notifyListeners();
  }

  void _go(Stage s) {
    stage = s;
    notifyListeners();
  }

  void _blocked(ApiException e) {
    block = e;
    _go(Stage.blocked);
  }

  /// С экрана блокировки: вдруг срок уже прошёл или модератор снял блокировку.
  Future<void> retryBlocked() async {
    try {
      await _resume();
      block = null;
    } on ApiException catch (e) {
      if (e.blocked) return;
      rethrow;
    }
  }

  /// Человек прочитал предупреждение. Если отметка не дошла до сервера — покажем ещё раз при следующем входе.
  Future<void> ackWarning() async {
    warning = '';
    notifyListeners();
    try {
      await api.ackWarning();
    } on ApiException {
      // Не страшно.
    }
  }

  /// При запуске: восстанавливаем сессию и понимаем, на каком шаге человек остановился.
  Future<void> start() async {
    await api.init();
    final prefs = await SharedPreferences.getInstance();
    api.token = prefs.getString(_tokenKey);
    if (api.token == null) return _go(Stage.phone);
    try {
      await _resume();
    } on ApiException catch (e) {
      if (e.blocked) return; // экран блокировки уже показан
      if (e.unauthorized) {
        await _forget();
        return _go(Stage.phone);
      }
      if (e.notRegistered) return _go(Stage.about);
      // Нет сети и т. п. — не выкидываем человека из аккаунта.
      return _go(Stage.home);
    }
  }

  Future<void> _resume() async {
    me = await api.me();
    warning = me!.warning;
    goals = await api.goals();
    interests = await api.interests();
    await loadProfile();
    if (activeGoals.isEmpty) return _go(Stage.goals);
    final prefs = await SharedPreferences.getInstance();
    final p = profile;
    // Вход на новом телефоне: если интересы и анкета уже есть, шаги не повторяем.
    final done =
        (prefs.getBool(_onboardedKey) ?? false) || (interests.isNotEmpty && p != null && profileCompletion(p) > 0);
    if (!done) {
      return _go(interests.isEmpty ? Stage.interests : Stage.profile);
    }
    _go(Stage.home);
  }

  /// Загружает анкету для напоминаний и профиля. Ошибку не пробрасываем: это не главное.
  Future<void> loadProfile() async {
    try {
      profile = await api.profile();
      notifyListeners();
    } on ApiException {
      // Без анкеты просто не покажем процент заполненности.
    }
  }

  void setProfile(ProfileFields f) {
    profile = f;
    notifyListeners();
  }

  /// Интересы пропущены при регистрации — дальше к анкете.
  void skipInterests() => _go(Stage.profile);

  void backToInterests() => _go(Stage.interests);

  /// Анкета сохранена или пропущена — регистрация закончена.
  Future<void> finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardedKey, true);
    _go(Stage.home);
  }

  Future<void> requestCode(String phoneE164, {String method = 'call'}) async {
    challenge = await api.startAuth(phoneE164, method: method);
    phone = phoneE164;
    if (stage != Stage.code) _go(Stage.code);
  }

  void changePhone() => _go(Stage.phone);

  Future<void> verify(String code) async => _signedIn(await api.verify(phone, code));

  Future<void> _signedIn(Session s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, s.token);
    if (!s.registered) return _go(Stage.about);
    await _resume();
  }

  /// Вход через VK ID / Яндекс ID. От провайдера берём только подтверждённый номер.
  /// false — человек закрыл окно входа.
  Future<bool> loginWith(String provider) async {
    final start = await api.oauthStart(provider);
    final scheme = Uri.parse(start.redirectUri).scheme;
    final back = await browser.open(Uri.parse(start.url), scheme);
    if (back == null) return false;
    // VK ID на мобильных может вернуть параметры одним JSON в payload.
    var params = Map<String, String>.of(back.queryParameters);
    final payload = params['payload'];
    if (payload != null) {
      params = {for (final e in (jsonDecode(payload) as Map<String, dynamic>).entries) e.key: '${e.value}'};
    }
    if (params['error'] != null || params['code'] == null) {
      throw const ApiException(400, 'Вход не подтверждён. Попробуйте ещё раз или войдите по звонку');
    }
    if (params['state'] != start.state) {
      throw const ApiException(400, 'Ответ сервиса входа не совпал — попробуйте ещё раз');
    }
    await _signedIn(
      await api.oauthFinish(provider, state: start.state, code: params['code']!, deviceId: params['device_id'] ?? ''),
    );
    return true;
  }

  Future<void> register(Registration r) async {
    await api.register(r);
    me = await api.me();
    _go(Stage.goals);
  }

  Future<void> saveGoals(List<String> ids) async {
    final next = [for (final id in ids) GoalSetting(id)];
    await api.setGoals(next);
    goals = next;
    if (stage == Stage.goals) return _go(Stage.interests);
    notifyListeners();
  }

  Future<void> saveInterests(List<MyInterest> items) async {
    await api.setInterests(items);
    interests = await api.interests();
    if (stage == Stage.interests) return _go(Stage.profile);
    feedChanged();
  }

  Future<void> loadMatches() async {
    matches = await api.matches();
    notifyListeners();
  }

  /// Убирает переписку из списков сразу, не дожидаясь перезагрузки.
  void forgetMatch(String matchId) {
    matches?.removeWhere((m) => m.matchId == matchId);
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await api.logout();
    } on ApiException {
      // Сессию всё равно забываем на устройстве.
    }
    await _forget();
    me = null;
    block = null;
    warning = '';
    goals = [];
    interests = [];
    profile = null;
    matches = null;
    _go(Stage.phone);
  }

  Future<void> _forget() async {
    api.token = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_onboardedKey);
  }
}
