import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../widgets/common.dart';
import '../widgets/profile_blocks.dart';
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
    final todo = state.interests.isEmpty || (profile != null && profileCompletion(profile) < 40);
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
              icon: Badge(
                isLabelVisible: fresh > 0,
                label: Text('$fresh'),
                child: const Icon(Icons.favorite_border),
              ),
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
