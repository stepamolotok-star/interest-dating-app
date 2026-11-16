import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:svoi/api/demo_api.dart';
import 'package:svoi/app.dart';
import 'package:svoi/models.dart';
import 'package:svoi/notifications.dart';
import 'package:svoi/screens/chat_screen.dart';

import 'helpers.dart';

void main() {
  setUp(() {
    DemoApi.laterMatchDelay = const Duration(milliseconds: 300);
    DemoApi.replyDelay = const Duration(milliseconds: 300);
  });
  tearDown(() {
    DemoApi.laterMatchDelay = const Duration(seconds: 20);
    DemoApi.replyDelay = const Duration(seconds: 6);
  });

  testWidgets('взаимный интерес позже — уведомление без имени; нажатие открывает переписку', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final n = SilentNotifier();
    final state = await tester.runAsync(() => registered(notifier: n));
    await tester.pumpWidget(SvoiApp(state: state!..start()));
    Future<void> wait([int ms = 900]) async {
      await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
      await tester.pumpAndSettle();
    }

    await wait();
    final cards = await tester.runAsync(() => state.api.feed('friendship'));
    // Первый интерес взаимный сразу, второй — чуть позже, с уведомлением.
    await tester.runAsync(() => state.api.expressInterest(cards![0].userId, 'friendship'));
    await tester.runAsync(() => state.api.expressInterest(cards![1].userId, 'friendship'));
    expect(n.shown, isEmpty);
    await wait();
    expect(n.shown, hasLength(1));
    final e = n.shown.single;
    expect((e.kind, e.title, e.body, e.private), ('match', 'Взаимный интерес', 'Можно начать разговор', true));
    expect(e.matchId, 'match-${cards![1].userId}');

    // Нажали на уведомление — открылась переписка.
    state.pendingChat = e.matchId;
    state.notifyListeners();
    await wait();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(state.openChatId, e.matchId);
  });

  testWidgets('о сообщении в открытой переписке не уведомляем; настройки слушаются', (tester) async {
    final n = SilentNotifier();
    final state = await tester.runAsync(() => registered(notifier: n));
    final api = state!.api;
    await tester.runAsync(() async {
      await state.start();
      final cards = await api.feed('friendship');
      final r = await api.expressInterest(cards[0].userId, 'friendship');
      expect(r.matched, isTrue);

      // Переписка открыта — ответ виден в ней, уведомления нет.
      state.openChatId = r.matchId;
      await api.send(r.matchId, 'Привет!');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(n.shown, isEmpty);

      // Каждый второй интерес в демо взаимен сразу, остальные — позже (это отдельное уведомление).
      Future<String> matchWith(int i) async {
        final r = await api.expressInterest(cards[i].userId, 'friendship');
        if (r.matched) return r.matchId;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return 'match-${cards[i].userId}';
      }

      List<PushEvent> messages() => n.shown.where((e) => e.kind == 'message').toList();

      // Подробности включены — имя и текст.
      await api.setNotificationSettings(NotificationSettings(showText: true));
      state.openChatId = null;
      final m2 = await matchWith(1);
      await api.send(m2, 'Привет!');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(messages(), hasLength(1));
      expect(messages().single.private, isFalse);
      expect(messages().single.title, cards[1].name);
      expect(messages().single.body, contains('совпали'));

      // Сообщения выключены — тишина.
      await api.setNotificationSettings(NotificationSettings(messages: false));
      final m3 = await matchWith(2);
      await api.send(m3, 'Привет!');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(messages(), hasLength(1));
    });
  });
}
