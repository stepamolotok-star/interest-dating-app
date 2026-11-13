import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/app.dart';
import 'package:svoi/screens/interests_screen.dart';
import 'package:svoi/state.dart';

/// Раскрытая категория не должна менять высоту, когда возвращаешься к ней прокруткой:
/// раньше она на кадр «сжималась» до заглушки, и лента под пальцем прыгала.
void main() {
  testWidgets('раскрытая категория сохраняет высоту при прокрутке туда-обратно', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final state = AppState(DemoApi());
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: const MaterialApp(home: InterestsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final list = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;
    final title = find.text('Общество и духовность');
    await tester.scrollUntilVisible(title, 200, scrollable: list);
    await tester.tap(title);
    await tester.pumpAndSettle();
    final tile = find.byKey(const PageStorageKey<String>('society'));
    final before = tester.getSize(tile).height;
    expect(before, greaterThan(200), reason: 'категория раскрыта и заполнена');

    // Уводим категорию далеко за экран и возвращаемся.
    await tester.drag(list, const Offset(0, 3000));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(title, 200, scrollable: list);
    await tester.pump(); // ровно один кадр — как видит палец
    expect(tester.getSize(tile).height, before);
  });
}
