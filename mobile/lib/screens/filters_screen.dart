import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Фильтры для одной цели. У большинства критериев есть «обязательно»:
/// без него критерий только поднимает подходящих людей выше, но никого не прячет.
class FiltersScreen extends StatefulWidget {
  const FiltersScreen({super.key, required this.goal});

  final String goal;

  @override
  State<FiltersScreen> createState() => _FiltersScreenState();
}

const _ageMin = 18, _ageMax = 80;
const _heightMin = 140, _heightMax = 210;
const _weightMin = 40, _weightMax = 150;

/// Цели, где можно фильтровать по росту и весу (как на сервере).
const physicalGoals = {'family', 'romance', 'casual'};

class _FiltersScreenState extends State<FiltersScreen> {
  GoalPrefs? _p;
  Object? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final p = await AppScope.read(context).api.prefs(widget.goal);
      if (mounted) setState(() => _p = p);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    await AppScope.read(context).api.setPrefs(widget.goal, _p!);
    if (mounted) Navigator.of(context).pop(true);
  }

  void _reset() => setState(() {
    final old = _p!;
    // Конкретные интересы в приложении пока не настраиваются — их не трогаем.
    _p = GoalPrefs(interests: old.interests, interestsRequired: old.interestsRequired);
  });

  void _toggleIn(List<String> list, String v) =>
      setState(() => list.contains(v) ? list.remove(v) : list.add(v));

  @override
  Widget build(BuildContext context) {
    final g = goalInfo(widget.goal);
    final p = _p;
    return Scaffold(
      appBar: AppBar(
        title: Text('Фильтры: ${goalShort[g.id] ?? g.label}'),
        actions: [
          if (p != null)
            TextButton(key: const Key('reset-filters'), onPressed: _reset, child: const Text('Сбросить')),
        ],
      ),
      body: p == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : TextButton(onPressed: _load, child: const Text('Не загрузилось. Повторить')),
            )
          : SafeArea(
              child: Column(
                children: [
                  Expanded(child: _form(p)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: BusyButton(label: 'Показать людей', color: g.color, onPressed: _save),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _form(GoalPrefs p) {
    final t = Theme.of(context).textTheme;
    final physical = physicalGoals.contains(widget.goal);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        Text(
          '«Обязательно» — показываем только подходящих. Без этой отметки критерий лишь поднимает '
          'подходящих выше, а тех, кто не указал, засчитываем наполовину. Фильтры работают в обе стороны: '
          'вас тоже увидят только те, чьим фильтрам вы подходите.',
          style: t.bodySmall,
        ),
        _Block(
          title: 'Кого показывать',
          hint: p.genders.isEmpty ? 'Сейчас — всех' : null,
          child: Wrap(
            spacing: 8,
            children: [
              for (final (id, label) in const [('female', 'Женщин'), ('male', 'Мужчин')])
                FilterChip(
                  key: Key('gender-$id'),
                  label: Text(label),
                  selected: p.genders.contains(id),
                  showCheckmark: false,
                  selectedColor: AppColors.accentTint,
                  onSelected: (_) => _toggleIn(p.genders, id),
                ),
            ],
          ),
        ),
        _Block(
          title: 'Возраст',
          trailing: Text(_rangeText(p.age, _ageMin, _ageMax, ''), style: t.titleMedium),
          child: _Range(
            key: const Key('age'),
            min: _ageMin,
            max: _ageMax,
            value: p.age,
            // Сервер принимает возраст только с нижней границей: «до 30» = «18–30».
            onChanged: (r) =>
                setState(() => p.age = r.isEmpty ? r : IntRange(r.min == 0 ? _ageMin : r.min, r.max)),
          ),
        ),
        _Block(
          title: 'Общих интересов — не меньше',
          child: Wrap(
            spacing: 8,
            children: [
              for (final n in const [0, 1, 2, 3, 5])
                ChoiceChip(
                  key: Key('min-shared-$n'),
                  label: Text(n == 0 ? 'Сколько угодно' : '$n'),
                  selected: p.minShared == n,
                  showCheckmark: false,
                  selectedColor: AppColors.accentTint,
                  onSelected: (_) => setState(() => p.minShared = n),
                ),
            ],
          ),
        ),
        SwitchListTile(
          key: const Key('verified-only'),
          contentPadding: EdgeInsets.zero,
          value: p.verifiedOnly,
          onChanged: (v) => setState(() => p.verifiedOnly = v),
          title: const Text('Только с проверенным фото', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        if (physical) ...[
          _Block(
            title: 'Рост',
            trailing: Text(_rangeText(p.height, _heightMin, _heightMax, ' см'), style: t.titleMedium),
            required: p.heightRequired,
            onRequired: p.height.isEmpty ? null : (v) => setState(() => p.heightRequired = v),
            child: _Range(
              key: const Key('height'),
              min: _heightMin,
              max: _heightMax,
              value: p.height,
              onChanged: (r) => setState(() => p.height = r),
            ),
          ),
          _Block(
            title: 'Вес',
            trailing: Text(_rangeText(p.weight, _weightMin, _weightMax, ' кг'), style: t.titleMedium),
            required: p.weightRequired,
            onRequired: p.weight.isEmpty ? null : (v) => setState(() => p.weightRequired = v),
            child: _Range(
              key: const Key('weight'),
              min: _weightMin,
              max: _weightMax,
              value: p.weight,
              onChanged: (r) => setState(() => p.weight = r),
            ),
          ),
        ],
        _Block(
          title: 'Привычки',
          required: p.habitsRequired,
          onRequired: p.habits.values.any((v) => v.isNotEmpty)
              ? (v) => setState(() => p.habitsRequired = v)
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final MapEntry(key: habit, value: options) in habitLabels.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 4),
                  child: Text(
                    habitTitles[habit] ?? habit,
                    style: t.bodySmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                _Multi(
                  keyPrefix: 'habit-$habit',
                  options: options,
                  selected: p.habits[habit] ?? const [],
                  onToggle: (v) => setState(() {
                    final list = p.habits.putIfAbsent(habit, () => []);
                    list.contains(v) ? list.remove(v) : list.add(v);
                    if (list.isEmpty) p.habits.remove(habit);
                  }),
                ),
              ],
            ],
          ),
        ),
        _Block(
          title: 'Питание',
          required: p.dietRequired,
          onRequired: p.diets.isEmpty ? null : (v) => setState(() => p.dietRequired = v),
          child: _Multi(
            keyPrefix: 'diet',
            options: {
              for (final e in dietLabels.entries)
                if (e.key != 'any') e.key: e.value,
            },
            selected: p.diets,
            onToggle: (v) => _toggleIn(p.diets, v),
          ),
        ),
        _Block(
          title: 'Знак зодиака',
          required: p.zodiacRequired,
          onRequired: p.zodiacs.isEmpty ? null : (v) => setState(() => p.zodiacRequired = v),
          child: _Multi(
            keyPrefix: 'zodiac',
            options: zodiacLabels,
            selected: p.zodiacs,
            onToggle: (v) => _toggleIn(p.zodiacs, v),
          ),
        ),
        _Block(
          title: 'Религия',
          hint: 'Учитываем только у тех, кто сам разрешил использовать её в подборе.',
          required: p.religionRequired,
          onRequired: p.religions.isEmpty ? null : (v) => setState(() => p.religionRequired = v),
          child: _Multi(
            keyPrefix: 'religion',
            options: religions,
            selected: p.religions,
            onToggle: (v) => _toggleIn(p.religions, v),
          ),
        ),
      ],
    );
  }
}

String _rangeText(IntRange r, int min, int max, String unit) {
  if (r.isEmpty) return 'любой';
  final lo = r.min == 0 ? min : r.min;
  final hi = r.max == 0 ? max : r.max;
  return r.max == 0 ? 'от $lo$unit' : '$lo–$hi$unit';
}

class _Block extends StatelessWidget {
  const _Block({
    required this.title,
    required this.child,
    this.hint,
    this.trailing,
    this.required,
    this.onRequired,
  });

  final String title;
  final String? hint;
  final Widget child;
  final Widget? trailing;

  /// null — у критерия нет «обязательно» (возраст и пол обязательны всегда).
  final bool? required;

  /// null — переключатель неактивен (критерий не задан).
  final ValueChanged<bool>? onRequired;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: t.titleMedium)),
              ?trailing,
              if (trailing != null && required != null) const SizedBox(width: 12),
              if (required != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Обязательно',
                      style: t.bodySmall?.copyWith(
                        color: onRequired == null ? AppColors.line : AppColors.muted,
                      ),
                    ),
                    Switch(key: Key('required-$title'), value: required!, onChanged: onRequired),
                  ],
                ),
            ],
          ),
          if (hint != null) Text(hint!, style: t.bodySmall),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _Multi extends StatelessWidget {
  const _Multi({
    required this.keyPrefix,
    required this.options,
    required this.selected,
    required this.onToggle,
  });

  final String keyPrefix;
  final Map<String, String> options;
  final List<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final MapEntry(key: id, value: label) in options.entries)
          FilterChip(
            key: Key('$keyPrefix-$id'),
            label: Text(label),
            selected: selected.contains(id),
            showCheckmark: false,
            selectedColor: AppColors.accentTint,
            onSelected: (_) => onToggle(id),
          ),
      ],
    );
  }
}

/// Ползунок «от–до». Крайние положения = граница не задана.
class _Range extends StatelessWidget {
  const _Range({
    super.key,
    required this.min,
    required this.max,
    required this.value,
    required this.onChanged,
  });

  final int min;
  final int max;
  final IntRange value;
  final ValueChanged<IntRange> onChanged;

  @override
  Widget build(BuildContext context) {
    final lo = value.min == 0 ? min : value.min.clamp(min, max);
    final hi = value.max == 0 ? max : value.max.clamp(min, max);
    return RangeSlider(
      min: min.toDouble(),
      max: max.toDouble(),
      divisions: max - min,
      values: RangeValues(lo.toDouble(), hi.toDouble()),
      onChanged: (v) {
        final a = v.start.round(), b = v.end.round();
        onChanged(IntRange(a == min ? 0 : a, b == max ? 0 : b));
      },
    );
  }
}
