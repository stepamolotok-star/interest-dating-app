import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/api.dart';
import '../app.dart';
import '../location.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'feed_tab.dart' show HiddenAvatar;
import 'match_screen.dart';
import 'nearby_settings_screen.dart';

/// «Рядом»: люди с общими интересами поблизости. Видеть других может только видимый сам;
/// вместо расстояния — интервал («до 1 км»), точного места никто не видит.
class NearbyTab extends StatefulWidget {
  const NearbyTab({super.key, required this.active, required this.onMatched});

  /// Вкладка открыта — только тогда отправляем геопозицию и обновляем радар.
  final bool active;
  final Future<void> Function(String matchId, bool write) onMatched;

  /// Как часто отправлять геопозицию и обновлять радар, пока вкладка открыта.
  static const every = Duration(minutes: 1);

  @override
  State<NearbyTab> createState() => _NearbyTabState();
}

class _NearbyTabState extends State<NearbyTab> {
  NearbyVisibility? _vis;
  String? _goal;
  List<FeedCard> _cards = [];
  LocationStatus? _status;
  String? _problem;
  bool _canOpenSettings = false;
  bool _loading = false;
  bool _acting = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.active) Future.microtask(_start);
  }

  @override
  void didUpdateWidget(NearbyTab old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _start();
    if (!widget.active && old.active) _timer?.cancel();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final state = AppScope.read(context);
    final goals = state.activeGoals;
    if (_goal == null || !goals.contains(_goal)) _goal = goals.isEmpty ? null : goals.first;
    try {
      final v = await state.api.visibility();
      if (!mounted) return;
      setState(() => _vis = v);
    } catch (e) {
      if (mounted) setState(() => _problem = e.toString());
      return;
    }
    _timer?.cancel();
    if (_vis!.active) {
      await _tick();
      _timer = Timer.periodic(NearbyTab.every, (_) => _tick());
    }
  }

  /// Отправить геопозицию и обновить радар.
  Future<void> _tick() async {
    final state = AppScope.read(context);
    final goal = _goal;
    if (goal == null) return;
    setState(() => _loading = true);
    try {
      final fix = await state.location.current();
      final status = await state.api.updateLocation(fix.lat, fix.lon, mocked: fix.mocked);
      if (!mounted) return;
      setState(() {
        _status = status;
        _problem = null;
      });
      if (status.reason == 'visibility_off') {
        // Время видимости истекло, пока вкладка была открыта.
        final v = await state.api.visibility();
        if (mounted) setState(() => _vis = v);
        _timer?.cancel();
        return;
      }
      if (!status.visible) {
        setState(() => _cards = []);
        return;
      }
      final cards = await state.api.radar(goal);
      if (mounted && goal == _goal) setState(() => _cards = cards);
    } on LocationError catch (e) {
      if (mounted) {
        setState(() {
          _problem = e.message;
          _canOpenSettings = e.canOpenSettings;
        });
      }
    } on ApiException catch (e) {
      // 429 — слишком часто: тихо ждём следующего раза.
      if (mounted && e.status != 429) setState(() => _problem = _capital(e.message));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _becomeVisible() async {
    final v = await showVisibilitySheet(context, current: _vis);
    if (v == null || !mounted) return;
    setState(() => _vis = v);
    await _start();
  }

  Future<void> _disappear() async {
    final api = AppScope.read(context).api;
    try {
      await api.disappear();
      _timer?.cancel();
      final v = await api.visibility();
      if (!mounted) return;
      setState(() {
        _vis = v;
        _cards = [];
        _status = null;
      });
      showInfo(context, 'Вас больше не видно в «Рядом»');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _pickGoal(String g) {
    if (g == _goal) return;
    setState(() {
      _goal = g;
      _cards = [];
    });
    _tick();
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
          showInfo(context, 'Отметили. Если интерес взаимный — сразу сообщим');
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
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NearbySettingsScreen()));
    if (mounted) await _start();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
            child: Row(
              children: [
                Expanded(child: Text('Рядом', style: Theme.of(context).textTheme.headlineSmall)),
                IconButton(
                  key: const Key('nearby-settings'),
                  tooltip: 'Настройки «Рядом»',
                  icon: const Icon(Icons.tune),
                  onPressed: _openSettings,
                ),
              ],
            ),
          ),
          Expanded(child: _body(state.activeGoals)),
        ],
      ),
    );
  }

  Widget _body(List<String> goals) {
    final v = _vis;
    if (v == null) {
      // Вкладку ещё не открывали — ничего не грузим и не крутим индикатор.
      if (!widget.active) return const SizedBox();
      return _problem == null
          ? const Center(child: CircularProgressIndicator())
          : _Problem(_problem!, _start);
    }
    if (!v.active) return _Intro(onTurnOn: _becomeVisible);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusStrip(vis: v, status: _status, onDisappear: _disappear, onChange: _becomeVisible),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            children: [
              for (final g in goals)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(goalShort[g] ?? g),
                    selected: g == _goal,
                    showCheckmark: false,
                    selectedColor: goalInfo(g).tint,
                    onSelected: (_) => _pickGoal(g),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: _list()),
      ],
    );
  }

  Widget _list() {
    if (_problem != null) {
      return _Problem(
        _problem!,
        _tick,
        extra: _canOpenSettings
            ? TextButton(
                onPressed: () => AppScope.read(context).location.openSettings(),
                child: const Text('Открыть настройки'),
              )
            : null,
      );
    }
    if (_status?.reason == 'private_zone') {
      return const _Message(
        icon: Icons.shield_moon_outlined,
        title: 'Вы в личной зоне',
        text:
            'Здесь вас никто не видит — и вы тоже не видите других. Выйдете из зоны — «Рядом» включится сам.',
      );
    }
    if (_loading && _cards.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_cards.isEmpty) {
      return _Message(
        icon: Icons.radar,
        title: 'Пока никого',
        text:
            'Рядом нет видимых людей с общими интересами. Обновляем раз в минуту — '
            'можно увеличить радиус или оставить вкладку открытой.',
        action: TextButton(onPressed: _tick, child: const Text('Обновить')),
      );
    }
    return RefreshIndicator(
      onRefresh: _tick,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        itemCount: _cards.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, i) => _NearbyCard(
          card: _cards[i],
          busy: _acting,
          onLike: () => _act(_cards[i], interested: true),
          onSkip: () => _act(_cards[i], interested: false),
        ),
      ),
    );
  }
}

String _capital(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String radiusLabel(int m) => m < 1000 ? '$m м' : '${m ~/ 1000} км';

/// Объяснение до включения: как устроена приватность.
class _Intro extends StatelessWidget {
  const _Intro({required this.onTurnOn});

  final VoidCallback onTurnOn;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    const points = [
      (
        Icons.visibility_outlined,
        'Видят только видимые',
        'Чтобы видеть других, нужно быть видимым самому. Без «подглядывания».',
      ),
      (Icons.blur_on, 'Без точного места', 'Только «до 500 м», «до 1 км» и т. п. Ни карты, ни направления.'),
      (Icons.shield_moon_outlined, 'Личные зоны', 'Дома, на работе — где скажете — вас не видно никогда.'),
      (Icons.timer_outlined, 'На время', 'Включайте на час-другой. Кнопка «Исчезнуть» выключает всё сразу.'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            children: [
              Text(
                'Люди с общими интересами — прямо сейчас поблизости. На концерте, в походе, в соседнем кафе.',
                style: t.bodyLarge?.copyWith(color: AppColors.muted),
              ),
              const SizedBox(height: 20),
              for (final (icon, title, text) in points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(color: AppColors.accentTint, shape: BoxShape.circle),
                        child: Icon(icon, size: 20, color: AppColors.accent),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: t.titleMedium),
                            const SizedBox(height: 2),
                            Text(text, style: t.bodySmall),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: FilledButton(
            key: const Key('become-visible'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: onTurnOn,
            child: const Text('Стать видимым'),
          ),
        ),
      ],
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    required this.vis,
    required this.status,
    required this.onDisappear,
    required this.onChange,
  });

  final NearbyVisibility vis;
  final LocationStatus? status;
  final VoidCallback onDisappear;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final hidden = status?.reason == 'private_zone';
    final until = vis.mode == 'timed' && vis.visibleUntil != null
        ? 'до ${_hhmm(vis.visibleUntil!)}'
        : 'пока открыто приложение';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: hidden ? AppColors.surface : AppColors.accentTint,
        borderRadius: BorderRadius.circular(14),
        border: hidden ? Border.all(color: AppColors.line) : null,
      ),
      child: Row(
        children: [
          Icon(
            hidden ? Icons.shield_moon_outlined : Icons.circle,
            size: hidden ? 18 : 10,
            color: AppColors.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: onChange,
              child: Text(
                hidden ? 'Личная зона — вас не видно' : 'Вас видно · $until · ${radiusLabel(vis.radiusM)}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.ink),
              ),
            ),
          ),
          TextButton(
            key: const Key('disappear'),
            onPressed: onDisappear,
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Исчезнуть'),
          ),
        ],
      ),
    );
  }
}

class _NearbyCard extends StatelessWidget {
  const _NearbyCard({required this.card, required this.busy, required this.onLike, required this.onSkip});

  final FeedCard card;
  final bool busy;
  final VoidCallback onLike;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final g = goalInfo(card.goal);
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.near_me, size: 18, color: g.color),
              const SizedBox(width: 6),
              Text(card.distance, style: t.titleMedium?.copyWith(color: g.color)),
              const SizedBox(width: 12),
              const Spacer(),
              if (card.ageLabel.isNotEmpty)
                Flexible(
                  child: Text(card.ageLabel, style: t.bodySmall, overflow: TextOverflow.ellipsis),
                ),
              if (card.ageVerified) ...[
                const SizedBox(width: 6),
                const Icon(Icons.verified_outlined, size: 16, color: AppColors.accent),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (card.name.isNotEmpty) ...[
            Row(
              children: [
                // В «Рядом» фото до взаимного интереса скрыто всегда.
                HiddenAvatar(goal: card.goal, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(card.name, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Text(card.explanation, style: t.titleMedium),
          if (card.about.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(card.about, style: t.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                  onPressed: busy ? null : onSkip,
                  child: const Text('Пропустить'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  key: Key('nearby-like-${card.userId}'),
                  style: FilledButton.styleFrom(
                    backgroundColor: g.color,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: busy ? null : onLike,
                  child: const Text('Интересно'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.text, this.action});

  final IconData icon;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
      children: [
        Icon(icon, size: 44, color: AppColors.accent),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(text, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
        if (action != null) ...[const SizedBox(height: 8), Center(child: action)],
      ],
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem(this.text, this.retry, {this.extra});

  final String text;
  final Future<void> Function() retry;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    return _Message(
      icon: Icons.location_off_outlined,
      title: 'Не получается',
      text: text,
      action: Column(
        children: [
          TextButton(onPressed: retry, child: const Text('Попробовать ещё раз')),
          ?extra,
        ],
      ),
    );
  }
}
