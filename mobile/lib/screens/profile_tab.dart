import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'goals_screen.dart';
import 'interests_screen.dart';

/// Профиль: кто я, цели, интересы, поддержка проекта и выход.
class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final me = state.me;
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Text(me == null ? 'Профиль' : '${me.name}, ${me.age}', style: t.headlineMedium),
          if (me != null && me.city.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(me.city, style: t.bodyLarge?.copyWith(color: AppColors.muted)),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (me?.ageVerified ?? false)
                const Tag('Возраст подтверждён', icon: Icons.verified_outlined, color: AppColors.accent)
              else
                const Tag('Возраст не подтверждён', icon: Icons.info_outline),
            ],
          ),
          const SizedBox(height: 24),
          _Section(
            title: 'Цели',
            onEdit: () => _open(context, const GoalsScreen()),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final g in state.activeGoals)
                  Tag(goalShort[g] ?? g, color: goalInfo(g).color, background: goalInfo(g).tint),
              ],
            ),
          ),
          _Section(
            title: 'Интересы',
            onEdit: () => _open(context, const InterestsScreen()),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final i in state.interests)
                  Tag(
                    i.name,
                    color: AppColors.accent,
                    background: AppColors.accentTint,
                    icon: i.seekingPartner ? Icons.people_alt_outlined : null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _Support(),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: () => AppScope.read(context).logout(), child: const Text('Выйти')),
        ],
      ),
    );
  }

  void _open(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.onEdit, required this.child});

  final String title;
  final VoidCallback onEdit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              TextButton(onPressed: onEdit, child: const Text('Изменить')),
            ],
          ),
          child,
        ],
      ),
    );
  }
}

/// «Поддержать проект»: приложение бесплатное и без рекламы.
class _Support extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: AppColors.accentTint, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Поддержать проект', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Свои — бесплатно и без рекламы. Если приложение помогло найти своих людей, '
            'можно поблагодарить: деньги пойдут на серверы и развитие.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: () => showInfo(context, 'Скоро: перевод через СБП'),
            child: const Text('Поблагодарить'),
          ),
        ],
      ),
    );
  }
}
