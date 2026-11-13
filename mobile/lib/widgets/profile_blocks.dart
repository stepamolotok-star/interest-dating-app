import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api.dart';
import '../models.dart';
import '../theme.dart';

/// Блоки анкеты. Одни и те же — при регистрации и в профиле.
enum ProfileBlock {
  about('О себе'),
  prompts('Вопросы'),
  looks('Внешность'),
  habits('Привычки'),
  diet('Питание'),
  religion('Религия');

  const ProfileBlock(this.title);
  final String title;
}

/// Блоки, по которым считаем заполненность. Религию не считаем:
/// это особая категория данных, подталкивать её указывать нельзя.
const completionBlocks = [
  ProfileBlock.about,
  ProfileBlock.prompts,
  ProfileBlock.looks,
  ProfileBlock.habits,
  ProfileBlock.diet,
];

/// Что заполнено в блоке — коротко, для строки в профиле; null — пусто.
String? blockSummary(ProfileBlock b, ProfileFields f) {
  final text = switch (b) {
    ProfileBlock.about => f.about,
    ProfileBlock.prompts => f.prompts.map((p) => p.question).join(' · '),
    ProfileBlock.looks => [
      if (f.heightCm != null) 'рост ${f.heightCm} см',
      if (f.weightKg != null) 'вес ${f.weightKg} кг',
      ?bodyTypes[f.bodyType]?.toLowerCase(),
    ].join(', '),
    ProfileBlock.habits => [
      for (final MapEntry(:key, :value) in f.habits.entries) ?habitLabels[key]?[value],
    ].join(', '),
    ProfileBlock.diet => dietLabels[f.diet] ?? '',
    ProfileBlock.religion => religions[f.religion] ?? '',
  };
  return text.trim().isEmpty ? null : text.trim();
}

/// Заполненность анкеты в процентах.
int profileCompletion(ProfileFields f) =>
    (completionBlocks.where((b) => blockSummary(b, f) != null).length * 100 / completionBlocks.length)
        .round();

/// Черновик анкеты: поля, видимость и текстовые контроллеры. Владелец вызывает [dispose].
class ProfileDraft {
  ProfileDraft(this.fields, Map<String, String> visibility)
    : visibility = Map.of(visibility),
      about = TextEditingController(text: fields.about),
      height = TextEditingController(text: fields.heightCm?.toString() ?? ''),
      weight = TextEditingController(text: fields.weightKg?.toString() ?? '');

  final ProfileFields fields;
  final Map<String, String> visibility;
  final visibilityChanges = <String, String>{};

  /// Человек дал отдельное согласие на религию (152-ФЗ, особая категория).
  bool grantSpecial = false;

  final TextEditingController about;
  final TextEditingController height;
  final TextEditingController weight;

  void setVisibility(String field, String v) {
    visibility[field] = v;
    visibilityChanges[field] = v;
  }

  /// Переносит текст из полей в анкету и проверяет числа.
  ProfileFields collect() {
    final f = fields
      ..about = about.text.trim()
      ..heightCm = int.tryParse(height.text)
      ..weightKg = int.tryParse(weight.text);
    if (f.heightCm != null && (f.heightCm! < 120 || f.heightCm! > 230)) {
      throw const ApiException(400, 'Рост — от 120 до 230 см');
    }
    if (f.weightKg != null && (f.weightKg! < 35 || f.weightKg! > 250)) {
      throw const ApiException(400, 'Вес — от 35 до 250 кг');
    }
    return f;
  }

  Future<ProfileFields> save(Api api) async {
    final f = collect();
    await api.updateProfile(f, grantSpecial: grantSpecial);
    if (visibilityChanges.isNotEmpty) {
      await api.setFieldVisibility(Map.of(visibilityChanges));
      visibilityChanges.clear();
    }
    return f;
  }

  void dispose() {
    about.dispose();
    height.dispose();
    weight.dispose();
  }
}

/// Форма из выбранных блоков анкеты. Не прокручивается сама — её кладут в список.
class ProfileBlocksForm extends StatefulWidget {
  const ProfileBlocksForm({super.key, required this.draft, required this.blocks});

  final ProfileDraft draft;
  final List<ProfileBlock> blocks;

  @override
  State<ProfileBlocksForm> createState() => _ProfileBlocksFormState();
}

class _ProfileBlocksFormState extends State<ProfileBlocksForm> {
  ProfileDraft get _d => widget.draft;
  ProfileFields get _f => widget.draft.fields;

  void _setVis(String field, String v) => setState(() => _d.setVisibility(field, v));

  Future<void> _pickReligion(String id) async {
    final f = _f;
    if (f.religion == id) {
      setState(() {
        f.religion = '';
        f.religionForMatching = false;
      });
      return;
    }
    if (f.religion.isEmpty && !_d.grantSpecial) {
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
      _d.grantSpecial = true;
    }
    setState(() => f.religion = id);
  }

  Future<void> _addPrompt() async {
    final used = _f.prompts.map((p) => p.question).toSet();
    final q = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
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
      final list = _f.prompts;
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final b in widget.blocks) _block(b)],
    );
  }

  Widget _block(ProfileBlock b) {
    final f = _f;
    final vis = _d.visibility;
    final t = Theme.of(context).textTheme;
    return switch (b) {
      ProfileBlock.about => _Section(
        title: b.title,
        visibility: vis['about'],
        onVisibility: (v) => _setVis('about', v),
        child: TextField(
          key: const Key('about'),
          controller: _d.about,
          maxLength: 500,
          minLines: 3,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Чем живёте, что ищете, чем можно увлечь'),
        ),
      ),
      ProfileBlock.prompts => _Section(
        title: b.title,
        hint: 'До трёх. На них проще ответить, чем написать о себе с нуля, и с них легко начать разговор.',
        visibility: vis['prompts'],
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
      ProfileBlock.looks => _Section(
        title: b.title,
        hint: 'По умолчанию только для подбора: в анкете не видно, но фильтры работают.',
        visibility: vis['height'],
        onVisibility: (v) {
          _setVis('height', v);
          _setVis('weight', v);
          _setVis('body_type', v);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: _NumberField(key: const Key('height'), controller: _d.height, label: 'Рост, см'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _NumberField(key: const Key('weight'), controller: _d.weight, label: 'Вес, кг'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Телосложение', style: t.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            _Choices(
              keyPrefix: 'body',
              options: bodyTypes,
              selected: f.bodyType.isEmpty ? null : f.bodyType,
              onChanged: (v) => setState(() => f.bodyType = v ?? ''),
            ),
          ],
        ),
      ),
      ProfileBlock.habits => _Section(
        title: b.title,
        visibility: vis['habits'],
        onVisibility: (v) => _setVis('habits', v),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final MapEntry(key: habit, value: options) in habitLabels.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 6),
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
              const SizedBox(height: 6),
            ],
          ],
        ),
      ),
      ProfileBlock.diet => _Section(
        title: b.title,
        visibility: vis['diet'],
        onVisibility: (v) => _setVis('diet', v),
        child: _Choices(
          keyPrefix: 'diet',
          options: dietLabels,
          selected: f.diet.isEmpty ? null : f.diet,
          onChanged: (v) => setState(() => f.diet = v ?? ''),
        ),
      ),
      ProfileBlock.religion => _Section(
        title: b.title,
        hint: 'Необязательно. Нужно отдельное согласие; по умолчанию её никто не видит.',
        visibility: vis['religion'],
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
    };
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
                Flexible(
                  child: PopupMenuButton<String>(
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
                          Flexible(
                            child: Text(
                              fieldVisibilityLabels[visibility] ?? visibility!,
                              overflow: TextOverflow.ellipsis,
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
