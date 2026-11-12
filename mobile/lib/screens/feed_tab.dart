import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'match_screen.dart';

/// Лента: анонимные карточки по выбранной цели, по одной за раз.
class FeedTab extends StatefulWidget {
  const FeedTab({super.key, required this.onMatched});

  /// Взаимный интерес: id совпадения и хочет ли человек сразу написать.
  final Future<void> Function(String matchId, bool write) onMatched;

  @override
  State<FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<FeedTab> {
  String? _goal;
  List<FeedCard> _cards = [];
  bool _loading = false;
  Object? _error;
  bool _acting = false;

  /// Короткая подсказка над карточкой. Не снекбар — он закрывал бы кнопки.
  String? _notice;
  Timer? _noticeTimer;

  @override
  void dispose() {
    _noticeTimer?.cancel();
    super.dispose();
  }

  void _notify(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = AppScope.of(context).activeGoals;
    if (_goal == null || !active.contains(_goal)) {
      final next = active.isEmpty ? null : active.first;
      if (next != _goal) {
        _goal = next;
        Future.microtask(_load);
      }
    }
  }

  Future<void> _load() async {
    final goal = _goal;
    if (goal == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cards = await AppScope.read(context).api.feed(goal);
      if (!mounted || goal != _goal) return;
      setState(() => _cards = cards);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _pickGoal(String g) {
    if (g == _goal) return;
    setState(() {
      _goal = g;
      _cards = [];
    });
    _load();
  }

  Future<void> _act(FeedCard card, {required bool interested}) async {
    if (_acting) return;
    setState(() => _acting = true);
    final api = AppScope.read(context).api;
    try {
      if (interested) {
        final res = await api.expressInterest(card.userId, card.goal);
        if (!mounted) return;
        setState(() => _cards.remove(card));
        if (res.matched) {
          final write = await Navigator.of(context)
              .push<bool>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => MatchScreen(card: card)));
          unawaited(widget.onMatched(res.matchId, write == true));
        } else {
          _notify('Отметили. Если интерес взаимный — сразу сообщим');
        }
      } else {
        await api.skip(card.userId, card.goal);
        if (mounted) setState(() => _cards.remove(card));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
    if (mounted && _cards.isEmpty) _load();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final active = state.activeGoals;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text('Свои', style: Theme.of(context).textTheme.headlineSmall),
          ),
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
              children: [
                for (final g in active)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _GoalChip(goal: goalInfo(g), selected: g == _goal, onTap: () => _pickGoal(g)),
                  ),
              ],
            ),
          ),
          if (state.api.isDemo)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: DemoBanner(text: 'Демо-режим: люди ненастоящие, каждый второй интерес — взаимный.'),
            ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: _notice == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle_outline, size: 16, color: AppColors.accent),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _notice!,
                            style: const TextStyle(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _cards.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _cards.isEmpty) {
      return _Empty(
        icon: Icons.wifi_off,
        title: 'Не удалось загрузить ленту',
        text: 'Проверьте интернет и попробуйте ещё раз.',
        action: TextButton(onPressed: _load, child: const Text('Обновить')),
      );
    }
    if (_cards.isEmpty) {
      return _Empty(
        icon: Icons.spa_outlined,
        title: 'Пока всё',
        text:
            'Новые люди появляются каждый день. Чтобы совпадений было больше — добавьте интересы '
            'или ещё одну цель.',
        action: TextButton(onPressed: _load, child: const Text('Обновить')),
      );
    }
    final card = _cards.first;
    final g = goalInfo(card.goal);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: PersonCard(key: ValueKey(card.userId), card: card),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('skip'),
                  onPressed: _acting ? null : () => _act(card, interested: false),
                  child: const Text('Пропустить'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('like'),
                  style: FilledButton.styleFrom(backgroundColor: g.color),
                  onPressed: _acting ? null : () => _act(card, interested: true),
                  icon: const Icon(Icons.favorite_border),
                  label: const Text('Интересно'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GoalChip extends StatelessWidget {
  const _GoalChip({required this.goal, required this.selected, required this.onTap});

  final GoalInfo goal;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? goal.color : AppColors.surface,
      shape: StadiumBorder(side: BorderSide(color: selected ? goal.color : AppColors.line)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Center(
            child: Text(
              goalShort[goal.id] ?? goal.label,
              style: TextStyle(fontWeight: FontWeight.w700, color: selected ? Colors.white : AppColors.ink),
            ),
          ),
        ),
      ),
    );
  }
}

/// Карточка человека: без имени и фото, только то, что он сам открыл.
class PersonCard extends StatelessWidget {
  const PersonCard({super.key, required this.card});

  final FeedCard card;

  @override
  Widget build(BuildContext context) {
    final g = goalInfo(card.goal);
    final t = Theme.of(context).textTheme;
    final habits = [
      for (final MapEntry(:key, :value) in card.habits.entries) ?habitLabels[key]?[value],
      ?dietLabels[card.diet],
      if (card.zodiac.isNotEmpty) card.zodiac,
    ];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Tag(goalShort[g.id] ?? g.label, color: g.color, background: g.tint),
              if (card.ageRange.isNotEmpty) Tag('${card.ageRange} лет'),
              if (card.distance.isNotEmpty) Tag(card.distance, icon: Icons.near_me_outlined),
              if (card.ageVerified)
                const Tag('Возраст подтверждён', icon: Icons.verified_outlined, color: AppColors.accent),
              if (card.photoVerified)
                const Tag('Фото проверено', icon: Icons.photo_camera_outlined, color: AppColors.accent),
            ],
          ),
          const SizedBox(height: 18),
          Text(card.explanation, style: t.headlineSmall),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in card.shared)
                Tag(
                  s.rare ? '${s.name} · редкое' : s.name,
                  color: AppColors.accent,
                  background: AppColors.accentTint,
                  icon: s.rare ? Icons.auto_awesome : null,
                ),
              if (card.otherInterests > 0) Tag('ещё ${card.otherInterests}'),
            ],
          ),
          if (card.about.isNotEmpty) ...[const SizedBox(height: 18), Text(card.about, style: t.bodyLarge)],
          for (final p in card.prompts) ...[
            const SizedBox(height: 16),
            Text(p.question, style: t.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(p.answer, style: t.bodyLarge),
          ],
          if (habits.isNotEmpty) ...[
            const SizedBox(height: 18),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final h in habits) Tag(h)]),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              const Icon(Icons.lock_outline, size: 16, color: AppColors.muted),
              const SizedBox(width: 6),
              Expanded(child: Text('Имя и фото откроются, если интерес будет взаимным', style: t.bodySmall)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.text, this.action});

  final IconData icon;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.accent),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(text, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}
