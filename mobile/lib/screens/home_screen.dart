import 'package:material_ui/material_ui.dart';

import '../theme.dart';
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
  Widget build(BuildContext context) {
    final tabs = [
      FeedTab(onOpenChats: () => setState(() => _tab = 3)),
      const _Soon(
        icon: Icons.radar,
        title: 'Рядом',
        text:
            'Покажем людей с общими интересами поблизости — только если вы оба включили видимость. '
            'Точного места никто не увидит, только «до 1 км» и т. п.',
      ),
      const _Soon(
        icon: Icons.favorite_border,
        title: 'Совпадения',
        text: 'Здесь будут все взаимные интересы.',
      ),
      const _Soon(
        icon: Icons.chat_bubble_outline,
        title: 'Чаты',
        text:
            'Переписка с теми, с кем интерес взаимный. В первом сообщении — без ссылок и контактов, '
            'это защищает от спама.',
      ),
      const ProfileTab(),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.style_outlined),
            selectedIcon: Icon(Icons.style),
            label: 'Лента',
          ),
          NavigationDestination(icon: Icon(Icons.radar), label: 'Рядом'),
          NavigationDestination(
            icon: Icon(Icons.favorite_border),
            selectedIcon: Icon(Icons.favorite),
            label: 'Совпадения',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Чаты',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Профиль',
          ),
        ],
      ),
    );
  }
}

/// Заглушка вкладки, которая появится в следующих версиях.
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
