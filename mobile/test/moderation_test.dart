import 'package:flutter_test/flutter_test.dart';
import 'package:svoi/api/api.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/app.dart';
import 'package:svoi/state.dart';

import 'helpers.dart';

/// Решения модератора доходят до человека: предупреждение один раз, блокировка — отдельным экраном.
void main() {
  testWidgets('предупреждение показывается один раз', (tester) async {
    final state = await tester.runAsync(registered);
    final api = state!.api as DemoApi;
    api.warning = 'Модератор проверил жалобы на вас: «Без угроз». При повторных нарушениях аккаунт заблокируют.';
    await tester.pumpWidget(SvoiApp(state: state..start()));
    await tester.pumpAndSettle();

    expect(find.text('Предупреждение'), findsOneWidget);
    expect(find.textContaining('«Без угроз»'), findsOneWidget);
    await tester.tap(find.text('Понятно'));
    await tester.pumpAndSettle();
    expect(find.text('Предупреждение'), findsNothing);
    expect(api.warning, isEmpty);
    expect(state.warning, isEmpty);
  });

  testWidgets('временная блокировка: экран со сроком, потом доступ возвращается', (tester) async {
    final state = await tester.runAsync(registered);
    final api = state!.api as DemoApi;
    api.blockedWith = ApiException(
      403,
      'аккаунт временно заблокирован за нарушение правил',
      blocked: true,
      until: DateTime.now().add(const Duration(days: 3)),
    );
    await tester.pumpWidget(SvoiApp(state: state..start()));
    await tester.pumpAndSettle();

    expect(state.stage, Stage.blocked);
    expect(find.text('Аккаунт временно заблокирован'), findsOneWidget);
    expect(find.textContaining('Доступ вернётся'), findsOneWidget);

    // Срок прошёл.
    api.blockedWith = null;
    await tester.runAsync(() async {
      await tester.tap(find.text('Проверить ещё раз'));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();
    expect(state.stage, Stage.home);
    expect(state.block, isNull);
  });

  testWidgets('блокировка навсегда посреди работы: только «Выйти»', (tester) async {
    final state = await tester.runAsync(registered);
    final api = state!.api as DemoApi;
    await tester.pumpWidget(SvoiApp(state: state..start()));
    await tester.pumpAndSettle();
    expect(state.stage, Stage.home);

    api.blockedWith = const ApiException(403, 'аккаунт заблокирован за нарушение правил', blocked: true);
    await tester.runAsync(() async {
      try {
        await state.loadMatches();
      } on ApiException {
        // Ожидаемо.
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('Аккаунт заблокирован'), findsOneWidget);
    expect(find.text('Проверить ещё раз'), findsNothing);

    await tester.runAsync(() async {
      await tester.tap(find.text('Выйти'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(state.stage, Stage.phone);
  });
}
