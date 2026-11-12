import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/api.dart';
import 'models.dart';

/// Где человек сейчас: вход, шаги регистрации или основное приложение.
enum Stage { loading, phone, code, about, goals, interests, home }

/// Состояние приложения: сессия, шаг регистрации и данные профиля.
class AppState extends ChangeNotifier {
  AppState(this.api);

  final Api api;

  static const _tokenKey = 'session_token';

  Stage stage = Stage.loading;
  String phone = '';
  Challenge? challenge;
  Me? me;
  List<GoalSetting> goals = [];
  List<MyInterest> interests = [];

  /// Цели, по которым сейчас ищем.
  List<String> get activeGoals => [
    for (final g in goals)
      if (g.active) g.goal,
  ];

  void _go(Stage s) {
    stage = s;
    notifyListeners();
  }

  /// При запуске: восстанавливаем сессию и понимаем, на каком шаге человек остановился.
  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    api.token = prefs.getString(_tokenKey);
    if (api.token == null) return _go(Stage.phone);
    try {
      await _resume();
    } on ApiException catch (e) {
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
    goals = await api.goals();
    interests = await api.interests();
    if (activeGoals.isEmpty) return _go(Stage.goals);
    if (interests.isEmpty) return _go(Stage.interests);
    _go(Stage.home);
  }

  Future<void> requestCode(String phoneE164, {String method = 'call'}) async {
    challenge = await api.startAuth(phoneE164, method: method);
    phone = phoneE164;
    if (stage != Stage.code) _go(Stage.code);
  }

  void changePhone() => _go(Stage.phone);

  Future<void> verify(String code) async {
    final s = await api.verify(phone, code);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, s.token);
    if (!s.registered) return _go(Stage.about);
    await _resume();
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
    if (interests.isEmpty) return _go(Stage.interests);
    notifyListeners();
  }

  Future<void> saveInterests(List<MyInterest> items) async {
    await api.setInterests(items);
    interests = await api.interests();
    _go(Stage.home);
  }

  Future<void> logout() async {
    try {
      await api.logout();
    } on ApiException {
      // Сессию всё равно забываем на устройстве.
    }
    await _forget();
    me = null;
    goals = [];
    interests = [];
    _go(Stage.phone);
  }

  Future<void> _forget() async {
    api.token = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }
}
