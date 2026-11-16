import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:svoi/app.dart';
import 'package:svoi/widgets/photos.dart';

import 'helpers.dart';

// PNG 1×1 — для теста содержимое не важно.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
  0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  setUp(() => PhotosEditor.pick = (_) async => _png);

  testWidgets('фото в профиле: добавить, сделать главным, удалить', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final state = await tester.runAsync(registered);
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
      await tester.pumpAndSettle();
    }

    await settle();
    await tester.tap(find.text('Профиль'));
    await settle();

    Future<void> add() async {
      final slot = find.byKey(Key('photo-slot-${state.photos.length}'));
      await tester.ensureVisible(slot);
      await tester.pumpAndSettle();
      await tester.tap(slot);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-gallery')));
      await settle();
    }

    await add();
    await add();
    expect(state.photos, hasLength(2));
    expect(find.text('Главное'), findsOneWidget);
    final second = state.photos[1].id;

    await tester.tap(find.byKey(const Key('photo-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-main')));
    await settle();
    expect(state.photos.first.id, second);

    await tester.tap(find.byKey(const Key('photo-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-main')), findsNothing, reason: 'главное уже главное');
    await tester.tap(find.byKey(const Key('photo-delete')));
    await settle();
    expect(state.photos, hasLength(1));
    expect((await tester.runAsync(state.api.myPhotos))!.map((p) => p.id), [state.photos.single.id]);
  });

  testWidgets('в ленте фото крупно сверху', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final state = await tester.runAsync(registered);
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-carousel')), findsWidgets);
  });
}
