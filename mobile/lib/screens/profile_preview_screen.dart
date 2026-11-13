import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../models.dart';
import '../theme.dart';
import 'feed_tab.dart' show PersonCard;

/// «Как меня видят другие»: своя карточка так, как её видят в ленте до взаимного интереса.
class ProfilePreviewScreen extends StatefulWidget {
  const ProfilePreviewScreen({super.key});

  @override
  State<ProfilePreviewScreen> createState() => _ProfilePreviewScreenState();
}

class _ProfilePreviewScreenState extends State<ProfilePreviewScreen> {
  Map<String, String>? _vis;
  String? _goal;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    final state = AppScope.read(context);
    try {
      if (state.profile == null) await state.loadProfile();
      final v = await state.api.fieldVisibility();
      if (mounted) setState(() => _vis = v);
    } catch (_) {
      if (mounted) setState(() => _vis = {});
    }
  }

  static String _ageRange(int age) {
    final lo = 18 + ((age < 18 ? 18 : age) - 18) ~/ 5 * 5;
    return '$lo–${lo + 4}';
  }

  FeedCard _card(String goal) {
    final state = AppScope.read(context);
    final me = state.me!;
    final f = state.profile ?? ProfileFields();
    final vis = _vis!;
    bool open(String field) => (vis[field] ?? 'anonymous') == 'anonymous';
    final names = [for (final i in state.interests) i.name];
    return FeedCard(
      userId: me.userId,
      name: me.name,
      age: f.ageAsRange ? 0 : me.age,
      ageRange: _ageRange(me.age),
      photosHidden: vis['photos'] == 'after_match' || goal == 'casual',
      goal: goal,
      score: 0,
      explanation: names.isEmpty ? 'Интересы не выбраны' : 'Тут будет, что у вас общего',
      shared: const [],
      otherInterests: names.length,
      others: names,
      photoVerified: me.photoVerified,
      ageVerified: me.ageVerified,
      about: open('about') ? f.about : '',
      prompts: open('prompts') ? f.prompts : const [],
      habits: open('habits') ? f.habits : const {},
      diet: open('diet') ? f.diet : '',
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final goals = state.activeGoals;
    final goal = _goal ?? (goals.isEmpty ? 'friendship' : goals.first);
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Как меня видят')),
      body: _vis == null || state.me == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                Text(
                  'Так вашу карточку видят в ленте до взаимного интереса. Общие интересы у каждого '
                  'свои — они будут сверху. Скрытое от ленты здесь не показано.',
                  style: t.bodySmall,
                ),
                if (goals.length > 1) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final g in goals)
                        ChoiceChip(
                          label: Text(goalShort[g] ?? g),
                          selected: g == goal,
                          showCheckmark: false,
                          selectedColor: goalInfo(g).tint,
                          onSelected: (_) => setState(() => _goal = g),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                PersonCard(key: ValueKey(goal), card: _card(goal), showAllInterests: true),
              ],
            ),
    );
  }
}
