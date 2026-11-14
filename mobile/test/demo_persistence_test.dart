import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/models.dart';
import 'package:svoi/state.dart';

/// Демо-режим переживает перезапуск приложения: регистрация, интересы, совпадения и переписка.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('после перезапуска человек остаётся зарегистрированным, переписка на месте', () async {
    SharedPreferences.setMockInitialValues({});
    final first = AppState(DemoApi());
    await first.start();
    await first.requestCode('+79123456789');
    await first.verify(DemoApi.demoCode);
    await first.register(
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
    await first.saveGoals(['friendship']);
    await first.saveInterests([MyInterest(id: 'fitness.strength.yoga'), MyInterest(id: 'society.inner.meditation')]);
    expect(first.stage, Stage.profile);
    await first.finishOnboarding();
    final card = (await first.api.feed('friendship')).first;
    final res = await first.api.expressInterest(card.userId, 'friendship');
    expect(res.matched, isTrue);
    await first.api.send(res.matchId, 'Привет! Давно занимаешься йогой?');
    await Future<void>.delayed(const Duration(milliseconds: 50)); // запись на диск

    // «Перезапуск»: новый API и новое состояние, общее только хранилище телефона.
    final second = AppState(DemoApi());
    await second.start();
    expect(second.stage, Stage.home);
    expect(second.me?.name, 'Аня');
    expect(second.interests.map((i) => i.id), contains('fitness.strength.yoga'));
    final matches = await second.api.matches();
    expect(matches.single.other.name, isNotEmpty);
    final messages = await second.api.messages(matches.single.matchId);
    expect(messages.first.body, 'Привет! Давно занимаешься йогой?');
    // Уже отмеченного человека лента больше не показывает.
    expect((await second.api.feed('friendship')).map((c) => c.userId), isNot(contains(card.userId)));
  });
}
