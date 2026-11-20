import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/app.dart';
import 'package:svoi/notifications.dart';
import 'package:svoi/screens/verify_screen.dart';
import 'package:svoi/widgets/photos.dart';

import 'helpers.dart';
import 'photos_test.dart' show testPng;

void main() {
  setUp(() {
    PhotosEditor.pick = (_) async => testPng;
    VerifyScreen.takeSelfie = () async => testPng;
    DemoApi.verifyDelay = const Duration(milliseconds: 2000);
  });
  tearDown(() => DemoApi.verifyDelay = const Duration(seconds: 8));

  testWidgets('селфи с жестом → на проверке → фото проверено', (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final n = SilentNotifier();
    final state = await tester.runAsync(() => registered(notifier: n));
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    Future<void> settle([int ms = 700]) async {
      await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
      await tester.pumpAndSettle();
    }

    await settle();
    await tester.tap(find.text('Профиль'));
    await settle();
    // Без фото проверять не с чем — призыва нет.
    expect(find.byKey(const Key('verify-start')), findsNothing);

    await tester.tap(find.byKey(const Key('photo-slot-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-gallery')));
    await settle();

    final start = find.byKey(const Key('verify-start'));
    await tester.ensureVisible(start);
    await tester.pumpAndSettle();
    await tester.tap(start);
    await settle();
    expect(find.byType(VerifyScreen), findsOneWidget);
    expect(find.byKey(const Key('gesture')), findsOneWidget);
    expect(state.verification.status, 'requested');
    expect(state.verification.gesture, isNotEmpty);

    await tester.tap(find.byKey(const Key('take-selfie')));
    await settle();
    expect(find.byKey(const Key('selfie-preview')), findsOneWidget);
    await tester.tap(find.byKey(const Key('send-selfie')));
    await settle(300);
    expect(find.byType(VerifyScreen), findsNothing);
    expect(state.verification.status, 'pending');
    expect(find.byKey(const Key('verify-pending')), findsOneWidget);

    // «Модератор» подтвердил: уведомление, значок в профиле.
    // Таймер «модератора» заведён внутри теста — двигаем часы теста.
    await tester.pump(const Duration(seconds: 3));
    await settle();
    expect(n.shown.map((e) => e.kind), contains('verify'));
    expect(state.verification.status, 'approved');
    expect(state.me!.photoVerified, isTrue);
    expect(find.byKey(const Key('verify-approved')), findsOneWidget);

    // Удалили единственное фото — значок снят.
    await tester.ensureVisible(find.byKey(const Key('photo-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-delete')));
    await settle();
    expect(state.photos, isEmpty, reason: 'фото удалено');
    expect(state.verification.status, 'none');
    expect(state.me!.photoVerified, isFalse);
  });
}
