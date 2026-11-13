import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/models.dart';
import 'package:svoi/state.dart';

/// Уже зарегистрированный человек в демо-режиме: цель «Дружба», три интереса.
/// Вызывать внутри tester.runAsync — демо-API делает настоящие паузы.
Future<AppState> registered() async {
  SharedPreferences.setMockInitialValues({});
  final api = DemoApi();
  await api.verify('+79123456789', DemoApi.demoCode);
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
  await api.setGoals(const [GoalSetting('friendship')]);
  await api.setInterests([
    MyInterest(id: 'fitness.strength.yoga'),
    MyInterest(id: 'society.inner.meditation'),
    MyInterest(id: 'society.inner.self_development'),
  ]);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('session_token', api.token!);
  await prefs.setBool('onboarding_done', true);
  return AppState(api);
}

/// Находит элемент в длинном ленивом списке: сначала наверх, потом вниз, пока не появится.
Future<void> reveal(WidgetTester tester, Finder f) async {
  if (f.evaluate().isNotEmpty) return;
  final list = find.byType(Scrollable).first;
  await tester.drag(list, const Offset(0, 5000));
  await tester.pumpAndSettle();
  if (f.evaluate().isEmpty) await tester.scrollUntilVisible(f, 250, scrollable: list);
}
