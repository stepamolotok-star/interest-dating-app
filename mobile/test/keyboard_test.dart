import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:svoi/app.dart';
import 'package:svoi/screens/home_screen.dart';
import 'package:svoi/screens/interests_screen.dart';

import 'helpers.dart';

/// Клавиатура поиска интересов не мешает: уходит при прокрутке и не возвращается после выбора.
void main() {
  testWidgets('клавиатура поиска интересов', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final state = await tester.runAsync(registered);
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    await tester.pumpAndSettle();
    // Экран интересов — как из профиля.
    Navigator.of(tester.element(find.byType(HomeScreen)))
        .push(MaterialPageRoute<void>(builder: (_) => const InterestsScreen()));
    await tester.pumpAndSettle();

    final search = find.byKey(const Key('interest-search'));
    // Клавиатура открыта, пока фокус в каком-нибудь текстовом поле.
    bool focused() =>
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;

    // Нажали в поиск — фокус там; пролистали — клавиатура ушла.
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(focused(), isTrue);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(focused(), isFalse);

    // Ищем, выбираем, закрываем панель — фокус в поиск не возвращается.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pumpAndSettle();
    await tester.tap(search);
    await tester.enterText(search, 'гитар');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('result-music.play.guitar')));
    await tester.pumpAndSettle();
    expect(focused(), isFalse);
    await tester.tap(find.text('Добавить'));
    await tester.pumpAndSettle();
    expect(focused(), isFalse);
  });
}
