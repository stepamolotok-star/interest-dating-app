import 'package:material_ui/material_ui.dart';

import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// «Это взаимно»: общие интересы и подсказка для первого сообщения.
/// Возвращает true, если человек хочет сразу написать.
class MatchScreen extends StatelessWidget {
  const MatchScreen({super.key, required this.card});

  final FeedCard card;

  @override
  Widget build(BuildContext context) {
    final g = goalInfo(card.goal);
    final t = Theme.of(context).textTheme;
    final hint = icebreaker(card.shared);
    return Scaffold(
      backgroundColor: g.tint,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const Spacer(),
              Icon(Icons.favorite, size: 48, color: g.color),
              const SizedBox(height: 16),
              Text('Это взаимно!', style: t.headlineMedium, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(
                'Теперь можно написать друг другу. ${card.explanation}.',
                style: t.bodyLarge?.copyWith(color: AppColors.muted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in card.shared) Tag(s.name, color: g.color, background: AppColors.surface),
                ],
              ),
              if (hint != null) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('С чего начать', style: t.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(hint, style: t.bodyLarge),
                    ],
                  ),
                ),
              ],
              const Spacer(),
              FilledButton(
                key: const Key('write'),
                style: FilledButton.styleFrom(backgroundColor: g.fill, foregroundColor: Colors.white),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Написать'),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Смотреть дальше'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Подсказка для первого сообщения по самому редкому общему интересу.
String? icebreaker(List<SharedInterest> shared) {
  if (shared.isEmpty) return null;
  final s = shared.firstWhere((s) => s.rare, orElse: () => shared.first);
  return 'Спросите, как началось увлечение «${s.name}» — и расскажите свою историю.';
}
