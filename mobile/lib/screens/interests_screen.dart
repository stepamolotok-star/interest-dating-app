import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/api.dart';
import '../app.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';

const minInterests = 3;
const maxInterests = 50;

/// Выбор интересов: поиск по каталогу или по категориям.
/// У каждого интереса — уровень и отметка «ищу партнёра».
class InterestsScreen extends StatefulWidget {
  const InterestsScreen({super.key, this.onboarding = false});

  final bool onboarding;

  @override
  State<InterestsScreen> createState() => _InterestsScreenState();
}

class _InterestsScreenState extends State<InterestsScreen> {
  late final Api _api = AppScope.read(context).api;
  late final Map<String, MyInterest> _selected = {
    for (final i in AppScope.read(context).interests)
      i.id: MyInterest(id: i.id, name: i.name, level: i.level, seekingPartner: i.seekingPartner),
  };
  final _query = TextEditingController();

  /// Загруженные подкатегории и интересы. Держим готовыми данными, а не Future:
  /// иначе при прокрутке назад раскрытая категория на кадр «сжимается» и лента прыгает.
  final _kids = <String, List<InterestNode>>{};
  final _loadingKids = <String>{};
  final _failedKids = <String>{};
  late final Future<List<InterestNode>> _categories = _api.categories();
  Future<List<InterestNode>>? _results;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  /// Загружает категорию целиком: подкатегории и их интересы — одним махом,
  /// чтобы раскрытая категория больше не меняла высоту.
  Future<void> _loadCategory(String id) async {
    if (_kids.containsKey(id) || _loadingKids.contains(id)) return;
    setState(() {
      _loadingKids.add(id);
      _failedKids.remove(id);
    });
    try {
      final children = await _api.children(id);
      final groups = children.where((n) => n.hasChildren).toList();
      final leaves = await Future.wait(groups.map((g) => _api.children(g.id)));
      if (!mounted) return;
      setState(() {
        _kids[id] = children;
        for (var i = 0; i < groups.length; i++) {
          _kids[groups[i].id] = leaves[i];
        }
      });
    } catch (_) {
      if (mounted) setState(() => _failedKids.add(id));
    } finally {
      if (mounted) setState(() => _loadingKids.remove(id));
    }
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      setState(() {
        _results = q.trim().length >= 2 ? _api.searchInterests(q.trim()) : null;
      });
    });
  }

  /// Нажатие на интерес: новый — добавляем и сразу спрашиваем уровень и «ищу партнёра»
  /// (иначе до настройки мало кто доберётся), уже выбранный — открываем его настройки.
  Future<void> _toggle(InterestNode n) async {
    final existing = _selected[n.id];
    if (existing != null) return _edit(existing);
    if (_selected.length >= maxInterests) {
      showInfo(context, 'Не больше $maxInterests интересов — оставьте самые важные');
      return;
    }
    final i = MyInterest(id: n.id, name: n.name);
    setState(() => _selected[n.id] = i);
    await _edit(i, isNew: true);
  }

  Future<void> _edit(MyInterest i, {bool isNew = false}) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: AppColors.bg,
      builder: (_) => _InterestSheet(
        interest: i,
        isNew: isNew,
        onRemove: () => setState(() => _selected.remove(i.id)),
        onChanged: () => setState(() {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = _selected.length;
    return StepScaffold(
      step: widget.onboarding ? 4 : null,
      onBack: widget.onboarding ? null : () => Navigator.of(context).pop(),
      scrollable: false,
      title: 'Ваши интересы',
      subtitle: 'По ним подбираем людей. У каждого интереса можно указать, насколько вы им увлечены.',
      button: BusyButton(
        label: n < minInterests
            ? 'Выберите ещё ${minInterests - n}'
            : widget.onboarding
            ? 'Готово — к людям'
            : 'Сохранить',
        onPressed: n < minInterests
            ? null
            : () async {
                await AppScope.read(context).saveInterests(_selected.values.toList());
                if (!widget.onboarding && context.mounted) Navigator.of(context).pop();
              },
      ),
      child: CustomScrollView(
        // Строим с запасом за краем экрана, чтобы при быстрой прокрутке не собирать плитки на лету.
        scrollCacheExtent: const ScrollCacheExtent.pixels(800),
        slivers: [
          SliverToBoxAdapter(
            child: TextField(
              key: const Key('interest-search'),
              controller: _query,
              onChanged: _onQuery,
              decoration: InputDecoration(
                hintText: 'Найти: йога, бонсай, эндуро…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _query.clear();
                          _onQuery('');
                        },
                      ),
              ),
            ),
          ),
          if (_selected.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final i in _selected.values) _SelectedChip(interest: i, onTap: () => _edit(i)),
                  ],
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          if (_results != null)
            _SearchResults(future: _results!, selected: _selected, onToggle: _toggle)
          else
            FutureBuilder<List<InterestNode>>(
              future: _categories,
              builder: (context, snap) {
                if (snap.hasError) {
                  return const SliverToBoxAdapter(child: _LoadError());
                }
                if (!snap.hasData) {
                  return const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  );
                }
                return SliverList.list(
                  children: [
                    for (final c in snap.data!)
                      _CategoryTile(
                        category: c,
                        kids: _kids,
                        failed: _failedKids.contains(c.id),
                        onExpand: () => _loadCategory(c.id),
                        selected: _selected,
                        onToggle: _toggle,
                      ),
                    const SizedBox(height: 12),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _SelectedChip extends StatelessWidget {
  const _SelectedChip({required this.interest, required this.onTap});

  final MyInterest interest;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accentTint,
      shape: const StadiumBorder(side: BorderSide(color: AppColors.accent)),
      child: InkWell(
        key: Key('chip-${interest.id}'),
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (interest.seekingPartner) ...[
                const Icon(Icons.people_alt_outlined, size: 15, color: AppColors.accent),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: interest.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: '  ·  ${levels[interest.level] ?? ''}'.toLowerCase(),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  style: const TextStyle(color: AppColors.accent),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.kids,
    required this.failed,
    required this.onExpand,
    required this.selected,
    required this.onToggle,
  });

  final InterestNode category;

  /// Загруженные дети по id узла; нет ключа — ещё не загружено.
  final Map<String, List<InterestNode>> kids;
  final bool failed;
  final VoidCallback onExpand;
  final Map<String, MyInterest> selected;
  final void Function(InterestNode) onToggle;

  @override
  Widget build(BuildContext context) {
    final children = kids[category.id];
    return ExpansionTile(
      key: PageStorageKey(category.id),
      // Без линий сверху и снизу — и без копии всей темы на каждую плитку.
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 12),
      title: Text(category.name, style: Theme.of(context).textTheme.titleMedium),
      expandedAlignment: Alignment.centerLeft,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      onExpansionChanged: (open) {
        if (open) onExpand();
      },
      children: [
        if (children != null)
          _CategoryBody(nodes: children, kids: kids, selected: selected, onToggle: onToggle)
        else if (failed)
          TextButton(onPressed: onExpand, child: const Text('Не загрузилось. Повторить'))
        else
          _AutoLoad(onLoad: onExpand),
      ],
    );
  }
}

/// Индикатор загрузки, который сам запускает загрузку — на случай, когда категория
/// раскрыта из сохранённого состояния и onExpansionChanged не вызывался.
class _AutoLoad extends StatefulWidget {
  const _AutoLoad({required this.onLoad});

  final VoidCallback onLoad;

  @override
  State<_AutoLoad> createState() => _AutoLoadState();
}

class _AutoLoadState extends State<_AutoLoad> {
  @override
  void initState() {
    super.initState();
    Future.microtask(widget.onLoad);
  }

  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: LinearProgressIndicator());
}

class _CategoryBody extends StatelessWidget {
  const _CategoryBody({
    required this.nodes,
    required this.kids,
    required this.selected,
    required this.onToggle,
  });

  final List<InterestNode> nodes;
  final Map<String, List<InterestNode>> kids;
  final Map<String, MyInterest> selected;
  final void Function(InterestNode) onToggle;

  @override
  Widget build(BuildContext context) {
    final leaves = nodes.where((n) => !n.hasChildren).toList();
    final groups = nodes.where((n) => n.hasChildren).toList();
    final label = Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (leaves.isNotEmpty) _Leaves(nodes: leaves, selected: selected, onToggle: onToggle),
        for (final g in groups) ...[
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 6),
            child: Text(g.name, style: label),
          ),
          _Leaves(nodes: kids[g.id] ?? const [], selected: selected, onToggle: onToggle),
        ],
      ],
    );
  }
}

class _Leaves extends StatelessWidget {
  const _Leaves({required this.nodes, required this.selected, required this.onToggle});

  final List<InterestNode> nodes;
  final Map<String, MyInterest> selected;
  final void Function(InterestNode) onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final n in nodes)
          FilterChip(
            key: Key('interest-${n.id}'),
            label: Text(n.name),
            selected: selected.containsKey(n.id),
            onSelected: (_) => onToggle(n),
            showCheckmark: false,
            selectedColor: AppColors.accentTint,
            backgroundColor: AppColors.surface,
            side: BorderSide(color: selected.containsKey(n.id) ? AppColors.accent : AppColors.line),
            labelStyle: TextStyle(
              fontWeight: FontWeight.w600,
              color: selected.containsKey(n.id) ? AppColors.accent : AppColors.ink,
            ),
            shape: const StadiumBorder(),
          ),
      ],
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.future, required this.selected, required this.onToggle});

  final Future<List<InterestNode>> future;
  final Map<String, MyInterest> selected;
  final void Function(InterestNode) onToggle;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<InterestNode>>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) return const SliverToBoxAdapter(child: _LoadError());
        if (!snap.hasData) {
          return const SliverToBoxAdapter(child: LinearProgressIndicator());
        }
        if (snap.data!.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Такого пока нет в каталоге. Попробуйте другое слово — мы регулярно добавляем новые увлечения.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return SliverList.list(
          children: [
            for (final n in snap.data!)
              ListTile(
                key: Key('result-${n.id}'),
                contentPadding: EdgeInsets.zero,
                title: Text(n.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: n.path.length > 1
                    ? Text(
                        n.path.sublist(0, n.path.length - 1).join(' › '),
                        style: Theme.of(context).textTheme.bodySmall,
                      )
                    : null,
                trailing: Icon(
                  selected.containsKey(n.id) ? Icons.check_circle : Icons.add_circle_outline,
                  color: selected.containsKey(n.id) ? AppColors.accent : AppColors.muted,
                ),
                onTap: () => onToggle(n),
              ),
          ],
        );
      },
    );
  }
}

class _InterestSheet extends StatefulWidget {
  const _InterestSheet({
    required this.interest,
    required this.onRemove,
    required this.onChanged,
    this.isNew = false,
  });

  final MyInterest interest;

  /// Только что добавлен: вместо «Убрать» — «Отмена», вместо «Готово» — «Добавить».
  final bool isNew;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  State<_InterestSheet> createState() => _InterestSheetState();
}

class _InterestSheetState extends State<_InterestSheet> {
  @override
  Widget build(BuildContext context) {
    final i = widget.interest;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(i.name, style: Theme.of(context).textTheme.headlineSmall),
            if (widget.isNew) ...[
              const SizedBox(height: 4),
              Text(
                'Отметьте, насколько увлечены, — так подбор точнее. Изменить можно в любой момент.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            Text('Насколько увлечены', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final MapEntry(key: id, value: label) in levels.entries)
                  ChoiceChip(
                    label: Text(label),
                    selected: i.level == id,
                    showCheckmark: false,
                    selectedColor: AppColors.accentTint,
                    onSelected: (_) {
                      setState(() => i.level = id);
                      widget.onChanged();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: i.seekingPartner,
              onChanged: (v) {
                setState(() => i.seekingPartner = v);
                widget.onChanged();
              },
              title: const Text('Ищу партнёра', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Такие совпадения поднимем выше в ленте'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      widget.onRemove();
                      Navigator.of(context).pop();
                    },
                    child: Text(widget.isNew ? 'Отмена' : 'Убрать'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(widget.isNew ? 'Добавить' : 'Готово'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text('Не удалось загрузить. Проверьте интернет.', style: Theme.of(context).textTheme.bodySmall),
  );
}
