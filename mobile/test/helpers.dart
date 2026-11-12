import 'package:shared_preferences/shared_preferences.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/models.dart';
import 'package:svoi/state.dart';

/// Уже зарегистрированный человек в демо-режиме: цель «Дружба», три интереса.
/// Вызывать внутри tester.runAsync — демо-API делает настоящие паузы.
Future<AppState> registered() async {
  final api = DemoApi();
  await api.verify('+79123456789', DemoApi.demoCode);
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
  await api.setGoals(const [GoalSetting('friendship')]);
  await api.setInterests([
    MyInterest(id: 'fitness.strength.yoga'),
    MyInterest(id: 'society.inner.meditation'),
    MyInterest(id: 'society.inner.self_development'),
  ]);
  SharedPreferences.setMockInitialValues({'session_token': api.token!});
  return AppState(api);
}
