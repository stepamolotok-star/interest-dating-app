import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/app.dart';
import 'package:svoi/code_autofill.dart';
import 'package:svoi/state.dart';

void main() {
  test('последние цифры номера звонка', () {
    expect(lastDigits('+7 (495) 123-45-67', 4), '4567');
    expect(lastDigits('84951234567', 4), '4567');
    expect(lastDigits('123', 4), isNull);
    expect(lastDigits(null, 4), isNull);
  });

  testWidgets('код из «звонка» подставляется сам и пускает дальше', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final state = AppState(DemoApi(), autofill: const DemoCodeAutofill(delay: Duration(seconds: 1)));
    await tester.pumpWidget(SvoiApp(state: state..start()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('phone')), '9123456789');
    await tester.pump();
    await tester.tap(find.text('Получить звонок'));
    await tester.pumpAndSettle();
    expect(find.text('Сейчас позвоним'), findsOneWidget);

    // Ничего не вводим — ждём «звонок».
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(state.stage, Stage.about);
  });
}
