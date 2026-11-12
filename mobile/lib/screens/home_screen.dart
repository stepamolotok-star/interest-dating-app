import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'conversations_tabs.dart';
import 'feed_tab.dart';
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
    final fresh = AppScope.of(context).newMatches.length;
    final tabs = [
      FeedTab(onMatched: _onMatched),
      const _Soon(
        icon: Icons.radar,
        title: 'Рядом',
        text:
            'Покажем людей с общими интересами поблизости — только если вы оба включили видимость. '
            'Точного места никто не увидит, только «до 1 км» и т. п.',
      ),
      const MatchesTab(),
      const ChatsTab(),
      const ProfileTab(),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: tabs),
      bottomNavigationBar: NavigationBar(
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
            label: 'Совпадения',
          ),
          const NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Чаты',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Профиль',
          ),
        ],
      ),
    );
  }
}

class _Soon extends StatelessWidget {
  const _Soon({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: AppColors.accent),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(text, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              const Text(
                'Скоро',
                style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
