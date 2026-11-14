import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:svoi/app.dart';
import 'package:svoi/screens/feed_tab.dart';

import 'helpers.dart';

/// «Фото только после взаимного интереса» сразу меняет уже открытую ленту, без смены цели.
void main() {
  testWidgets('переключатель фото обновляет карточки в ленте', (tester) async {
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
    expect(find.byType(HiddenAvatar), findsNothing);

    Future<void> toggle() async {
      await tester.tap(find.text('Профиль'));
      await settle();
      final sw = find.byKey(const Key('photos-after-match'));
      await reveal(tester, sw);
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(sw);
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Лента'));
      await settle();
    }

    await toggle();
    expect(find.byType(HiddenAvatar), findsOneWidget);
    await toggle();
    expect(find.byType(HiddenAvatar), findsNothing);
  });
}
