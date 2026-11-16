import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../widgets/common.dart';
import '../widgets/profile_blocks.dart';
import 'blocked_screen.dart';
import 'conversations_tabs.dart';
import 'feed_tab.dart';
import 'nearby_tab.dart';
import 'profile_tab.dart';

/// Основное приложение: пять вкладок внизу.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadMatches);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _showWarning();
      await _askNotifications();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Нажали на уведомление — открываем переписку.
    final state = AppScope.of(context);
    final id = state.pendingChat;
    if (id != null) {
      state.pendingChat = null;
      Future.microtask(() => _onMatched(id, true));
    }
  }

  Future<void> _showWarning() async {
    final state = AppScope.read(context);
    if (!mounted || state.warning.isEmpty) return;
    await showModeratorWarning(context, state.warning);
    await state.ackWarning();
  }

  /// Один раз объясняем, зачем уведомления, и только потом показываем системный запрос.
  Future<void> _askNotifications() async {
    final state = AppScope.read(context);
    if (!mounted || !await state.shouldAskNotifications() || !mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.notifications_active_outlined),
        title: const Text('Сообщать о взаимном интересе?'),
        content: const Text(
          'Пришлём уведомление, когда кто-то ответит взаимностью или напишет. '
          'Имя и текст на экране блокировки не показываем — это можно включить в профиле.',
        ),
        actions: [
          TextButton(
            key: const Key('notif-later'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Не сейчас'),
          ),
          FilledButton(
            key: const Key('notif-yes'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Включить'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await state.askNotifications();
    } else {
      await state.declineNotifications();
    }
  }

  Future<void> _loadMatches() async {
    try {
      await AppScope.read(context).loadMatches();
    } catch (e) {
      if (mounted && (_tab == 2 || _tab == 3)) showError(context, e);
    }
  }

  void _select(int i) {
    setState(() => _tab = i);
    if (i == 2 || i == 3) _loadMatches();
  }

  /// После взаимного интереса в ленте: обновить списки и, если просили, открыть переписку.
  Future<void> _onMatched(String matchId, bool write) async {
    await _loadMatches();
    if (!mounted || !write) return;
    final match = AppScope.read(context).matches?.where((m) => m.matchId == matchId).firstOrNull;
    setState(() => _tab = 3);
    if (match != null) await openChat(context, match);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final fresh = state.newMatches.length;
    // Точка на «Профиле»: не выбраны интересы или анкета почти пустая.
    final profile = state.profile;
    final todo =
        state.interests.isEmpty ||
        (profile != null && profileCompletion(profile, photos: state.photos.isNotEmpty) < 40);
    final tabs = [
      FeedTab(onMatched: _onMatched),
      NearbyTab(active: _tab == 1, onMatched: _onMatched),
      const MatchesTab(),
      const ChatsTab(),
      const ProfileTab(),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: tabs),
      // Подписи вкладок не растягиваем сверх 1,15 от системного шрифта, иначе они не влезают в одну строку.
      bottomNavigationBar: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.15,
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: _select,
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.style_outlined),
              selectedIcon: Icon(Icons.style),
              label: 'Лента',
            ),
            const NavigationDestination(icon: Icon(Icons.radar), label: 'Рядом'),
            NavigationDestination(
              icon: Badge(isLabelVisible: fresh > 0, label: Text('$fresh'), child: const Icon(Icons.favorite_border)),
              selectedIcon: const Icon(Icons.favorite),
              // Короткое слово: «Совпадения» на телефонах с крупным шрифтом переносилось на две строки.
              label: 'Взаимно',
            ),
            const NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Чаты',
            ),
            NavigationDestination(
              icon: Badge(isLabelVisible: todo, child: const Icon(Icons.person_outline)),
              selectedIcon: const Icon(Icons.person),
              label: 'Профиль',
            ),
          ],
        ),
      ),
    );
  }
}
