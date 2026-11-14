import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:svoi/app.dart';
import 'package:svoi/theme.dart';

import 'helpers.dart';

/// Тема переключается в профиле, сохраняется и перекрашивает уже открытые экраны.
void main() {
  testWidgets('тёмная тема из профиля', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    addTearDown(() => AppColors.dark = false);

    final state = await tester.runAsync(registered);
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(AppColors.dark, isFalse);

    Color bg() =>
        tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor ??
        Theme.of(tester.element(find.byType(Scaffold).first)).scaffoldBackgroundColor;
    expect(bg(), lightPalette.bg);

    final dark = find.byKey(const Key('theme-dark'));
    await reveal(tester, dark);
    await tester.ensureVisible(dark);
    await tester.pumpAndSettle();
    await tester.tap(dark);
    await tester.pumpAndSettle();

    expect(AppColors.dark, isTrue);
    expect(bg(), darkPalette.bg);
    expect((await SharedPreferences.getInstance()).getString('theme_mode'), 'dark');

    // Светлая — обратно.
    await tester.tap(find.byKey(const Key('theme-light')));
    await tester.pumpAndSettle();
    expect(AppColors.dark, isFalse);
    expect(bg(), lightPalette.bg);
  });
}
