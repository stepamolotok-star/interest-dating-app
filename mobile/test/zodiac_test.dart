import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:svoi/app.dart';

import 'helpers.dart';

/// Знак зодиака виден по умолчанию; в «Приватности» его можно скрыть.
void main() {
  testWidgets('«Скрыть знак зодиака» выключен по умолчанию и скрывает знак', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final state = await tester.runAsync(registered);
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pumpAndSettle();
    }

    await settle();
    expect((await tester.runAsync(state.api.profile))!.showZodiac, isTrue);

    await tester.tap(find.text('Профиль'));
    await settle();
    final sw = find.byKey(const Key('hide-zodiac'));
    await reveal(tester, sw);
    await tester.ensureVisible(sw);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(sw).value, isFalse);

    await tester.runAsync(() async {
      await tester.tap(sw);
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(sw).value, isTrue);
    expect((await tester.runAsync(state.api.profile))!.showZodiac, isFalse);
  });
}
