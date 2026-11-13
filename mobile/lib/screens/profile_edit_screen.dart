import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api.dart';
import '../app.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Анкета: о себе, ответы на вопросы, внешность, привычки, питание, религия.
/// У каждого блока своя видимость: все в ленте / после взаимного интереса / только для подбора / никто.
class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late final Api _api = AppScope.read(context).api;
  ProfileFields? _f;
  Map<String, String> _vis = {};
  final _visChanges = <String, String>{};
  final _about = TextEditingController();
  final _height = TextEditingController();
  final _weight = TextEditingController();
  bool _grantSpecial = false;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _about.dispose();
    _height.dispose();
    _weight.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final f = await _api.profile();
      final v = await _api.fieldVisibility();
      if (!mounted) return;
      setState(() {
        _f = f;
        _vis = v;
        _about.text = f.about;
        _height.text = f.heightCm?.toString() ?? '';
        _weight.text = f.weightKg?.toString() ?? '';
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  Future<void> _save() async {
    final f = _f!
      ..about = _about.text.trim()
      ..heightCm = int.tryParse(_height.text)
      ..weightKg = int.tryParse(_weight.text);
    if (f.heightCm != null && (f.heightCm! < 120 || f.heightCm! > 230)) {
      throw const ApiException(400, 'Рост — от 120 до 230 см');
    }
    if (f.weightKg != null && (f.weightKg! < 35 || f.weightKg! > 250)) {
      throw const ApiException(400, 'Вес — от 35 до 250 кг');
    }
    await _api.updateProfile(f, grantSpecial: _grantSpecial);
    if (_visChanges.isNotEmpty) await _api.setFieldVisibility(_visChanges);
    if (!mounted) return;
    showInfo(context, 'Анкета сохранена');
    Navigator.of(context).pop(true);
  }

  void _setVis(String field, String v) => setState(() {
    _vis[field] = v;
    _visChanges[field] = v;
  });

  Future<void> _pickReligion(String id) async {
    final f = _f!;
    if (f.religion == id) {
      setState(() {
        f.religion = '';
        f.religionForMatching = false;
      });
      return;
    }
    if (f.religion.isEmpty && !_grantSpecial) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Отдельное согласие'),
          content: const Text(
            'Религиозные убеждения — особая категория персональных данных. Чтобы указать религию, '
            'нужно ваше отдельное согласие на её обработку. По умолчанию её никто не видит; '
            'можно учитывать её только в подборе. Отозвать согласие можно в любой момент, убрав религию.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Не указывать')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Даю согласие')),
          ],
        ),
      );
      if (ok != true) return;
      _grantSpecial = true;
    }
    setState(() => f.religion = id);
  }

  Future<void> _addPrompt() async {
    final used = _f!.prompts.map((p) => p.question).toSet();
    final q = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.bg,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final q in promptQuestions.where((q) => !used.contains(q)))
              ListTile(title: Text(q), onTap: () => Navigator.of(ctx).pop(q)),
          ],
        ),
      ),
    );
    if (q == null || !mounted) return;
    await _editPrompt(Prompt(q, ''));
  }

  Future<void> _editPrompt(Prompt p) async {
    final answer = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.bg,
      builder: (_) => _PromptSheet(prompt: p),
    );
    if (answer == null || answer.isEmpty || !mounted) return;
    setState(() {
      final list = _f!.prompts;
      final i = list.indexWhere((x) => x.question == p.question);
      if (i >= 0) {
        list[i] = Prompt(p.question, answer);
      } else {
        list.add(Prompt(p.question, answer));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final f = _f;
    return Scaffold(
      appBar: AppBar(title: const Text('Анкета')),
      body: f == null
          ? Center(
              child: _loadError == null
                  ? const CircularProgressIndicator()
                  : TextButton(onPressed: _load, child: const Text('Не загрузилось. Повторить')),
            )
          : SafeArea(
              child: Column(
                children: [
                  Expanded(child: _form(f)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: BusyButton(label: 'Сохранить', onPressed: _save),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _form(ProfileFields f) {
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        _Section(
          title: 'О себе',
          visibility: _vis['about'],
          onVisibility: (v) => _setVis('about', v),
          child: TextField(
            key: const Key('about'),
            controller: _about,
            maxLength: 500,
            minLines: 3,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Чем живёте, что ищете, чем можно увлечь'),
          ),
        ),
        _Section(
          title: 'Вопросы',
          hint: 'До трёх. На них проще ответить, чем написать о себе с нуля, и с них легко начать разговор.',
          visibility: _vis['prompts'],
          onVisibility: (v) => _setVis('prompts', v),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final p in f.prompts)
                Card(
                  elevation: 0,
                  color: AppColors.surface,
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(color: AppColors.line),
                  ),
                  child: ListTile(
                    title: Text(p.question, style: t.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
                    subtitle: Text(p.answer, style: t.bodyLarge),
                    onTap: () => _editPrompt(p),
                    trailing: IconButton(
                      tooltip: 'Убрать',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => f.prompts.remove(p)),
                    ),
                  ),
                ),
              if (f.prompts.length < 3)
                OutlinedButton.icon(
                  key: const Key('add-prompt'),
                  onPressed: _addPrompt,
                  icon: const Icon(Icons.add),
                  label: const Text('Ответить на вопрос'),
                ),
            ],
          ),
        ),
        _Section(
          title: 'Привычки',
          visibility: _vis['habits'],
          onVisibility: (v) => _setVis('habits', v),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final MapEntry(key: habit, value: options) in habitLabels.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 6),
                  child: Text(
                    habitTitles[habit] ?? habit,
                    style: t.bodySmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                _Choices(
                  keyPrefix: 'habit-$habit',
                  options: options,
                  selected: f.habits[habit],
                  onChanged: (v) => setState(() => v == null ? f.habits.remove(habit) : f.habits[habit] = v),
                ),
              ],
            ],
          ),
        ),
        _Section(
          title: 'Питание',
          visibility: _vis['diet'],
          onVisibility: (v) => _setVis('diet', v),
          child: _Choices(
            keyPrefix: 'diet',
            options: dietLabels,
            selected: f.diet.isEmpty ? null : f.diet,
            onChanged: (v) => setState(() => f.diet = v ?? ''),
          ),
        ),
        _Section(
          title: 'Рост и вес',
          hint: 'По умолчанию только для подбора: в анкете их не видно, но фильтры по ним работают.',
          visibility: _vis['height'],
          onVisibility: (v) {
            _setVis('height', v);
            _setVis('weight', v);
          },
          child: Row(
            children: [
              Expanded(
                child: _NumberField(key: const Key('height'), controller: _height, label: 'Рост, см'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NumberField(key: const Key('weight'), controller: _weight, label: 'Вес, кг'),
              ),
            ],
          ),
        ),
        _Section(
          title: 'Телосложение',
          visibility: _vis['body_type'],
          onVisibility: (v) => _setVis('body_type', v),
          child: _Choices(
            keyPrefix: 'body',
            options: bodyTypes,
            selected: f.bodyType.isEmpty ? null : f.bodyType,
            onChanged: (v) => setState(() => f.bodyType = v ?? ''),
          ),
        ),
        _Section(
          title: 'Возраст',
          child: SwitchListTile(
            key: const Key('age-as-range'),
            contentPadding: EdgeInsets.zero,
            value: f.ageAsRange,
            onChanged: (v) => setState(() => f.ageAsRange = v),
            title: const Text('Показывать диапазоном'),
            subtitle: const Text(
              'Например, «28–32» вместо «30 лет». Фильтры по возрасту работают как обычно',
            ),
          ),
        ),
        _Section(
          title: 'Знак зодиака',
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: f.showZodiac,
            onChanged: (v) => setState(() => f.showZodiac = v),
            title: const Text('Показывать в анкете'),
            subtitle: const Text('Считаем по дате рождения, саму дату никто не видит'),
          ),
        ),
        _Section(
          title: 'Религия',
          hint: 'Необязательно. Нужно отдельное согласие; по умолчанию её никто не видит.',
          visibility: _vis['religion'],
          onVisibility: (v) => _setVis('religion', v),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final MapEntry(key: id, value: label) in religions.entries)
                    ChoiceChip(
                      key: Key('religion-$id'),
                      label: Text(label),
                      selected: f.religion == id,
                      showCheckmark: false,
                      selectedColor: AppColors.accentTint,
                      onSelected: (_) => _pickReligion(id),
                    ),
                ],
              ),
              if (f.religion.isNotEmpty)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: f.religionForMatching,
                  onChanged: (v) => setState(() => f.religionForMatching = v),
                  title: const Text('Учитывать при подборе'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.hint, this.visibility, this.onVisibility});

  final String title;
  final String? hint;
  final Widget child;
  final String? visibility;
  final ValueChanged<String>? onVisibility;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: t.titleMedium)),
              if (visibility != null && onVisibility != null)
                PopupMenuButton<String>(
                  tooltip: 'Кто видит',
                  initialValue: visibility,
                  onSelected: onVisibility,
                  itemBuilder: (_) => [
                    for (final MapEntry(key: id, value: label) in fieldVisibilityLabels.entries)
                      PopupMenuItem(value: id, child: Text(label)),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.visibility_outlined, size: 16, color: AppColors.accent),
                        const SizedBox(width: 4),
                        Text(
                          fieldVisibilityLabels[visibility] ?? visibility!,
                          style: const TextStyle(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (hint != null) ...[const SizedBox(height: 2), Text(hint!, style: t.bodySmall)],
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Выбор одного значения; повторное нажатие снимает выбор.
class _Choices extends StatelessWidget {
  const _Choices({
    required this.keyPrefix,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final String keyPrefix;
  final Map<String, String> options;
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final MapEntry(key: id, value: label) in options.entries)
          ChoiceChip(
            key: Key('$keyPrefix-$id'),
            label: Text(label),
            selected: selected == id,
            showCheckmark: false,
            selectedColor: AppColors.accentTint,
            onSelected: (_) => onChanged(selected == id ? null : id),
          ),
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({super.key, required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
    decoration: InputDecoration(labelText: label),
  );
}

/// Ответ на вопрос анкеты. Свой State — чтобы поле жило, пока панель закрывается.
class _PromptSheet extends StatefulWidget {
  const _PromptSheet({required this.prompt});

  final Prompt prompt;

  @override
  State<_PromptSheet> createState() => _PromptSheetState();
}

class _PromptSheetState extends State<_PromptSheet> {
  late final _ctrl = TextEditingController(text: widget.prompt.answer);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.prompt.question, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          TextField(
            key: const Key('prompt-answer'),
            controller: _ctrl,
            autofocus: true,
            maxLength: 150,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Ваш ответ'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
  }
}
