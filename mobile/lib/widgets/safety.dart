import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../models.dart';
import '../theme.dart';
import 'common.dart';

/// Круглая аватарка с первой буквой имени (фото подключим позже).
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, required this.goal, this.size = 48});

  final String name;
  final String goal;
  final double size;

  @override
  Widget build(BuildContext context) {
    final g = goalInfo(goal);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: g.tint, shape: BoxShape.circle),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          fontFamily: 'Unbounded',
          fontWeight: FontWeight.w700,
          fontSize: size * 0.42,
          color: g.color,
        ),
      ),
    );
  }
}

/// Причины жалобы — те же коды, что на сервере (chat.ReportReasons).
const reportReasons = [
  ('threat', 'Угрозы'),
  ('harassment', 'Оскорбления или домогательства'),
  ('stalking', 'Преследование или слежка'),
  ('minor', 'Похоже, что это несовершеннолетний'),
  ('fake', 'Фейковый профиль'),
  ('spam', 'Спам или реклама'),
  ('paid_services', 'Предлагает платные услуги'),
  ('explicit', 'Откровенные фото или сообщения'),
  ('other', 'Другое'),
];

/// Анкета собеседника после совпадения.
Future<void> showPersonSheet(BuildContext context, Match match) {
  final p = match.other;
  final g = goalInfo(match.goal);
  final t = Theme.of(context).textTheme;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.bg,
    builder: (_) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Avatar(name: p.name, goal: match.goal, size: 64),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${p.name}, ${p.age}', style: t.headlineSmall),
                      const SizedBox(height: 6),
                      Tag(goalShort[g.id] ?? g.label, color: g.color, background: g.tint),
                    ],
                  ),
                ),
              ],
            ),
            if (p.about.isNotEmpty) ...[const SizedBox(height: 18), Text(p.about, style: t.bodyLarge)],
            for (final q in p.prompts) ...[
              const SizedBox(height: 14),
              Text(q.question, style: t.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(q.answer, style: t.bodyLarge),
            ],
            if (p.interests.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text('Интересы', style: t.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final i in p.interests)
                    Tag(i, color: AppColors.accent, background: AppColors.accentTint),
                ],
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Жалоба. Возвращает true, если человека заодно заблокировали.
Future<bool> showReportSheet(BuildContext context, Person person) async {
  final blocked = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.bg,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _ReportSheet(person: person),
    ),
  );
  return blocked ?? false;
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.person});

  final Person person;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  String? _reason;
  bool _block = true;
  final _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final api = AppScope.read(context).api;
    final urgent = await api.report(widget.person.userId, _reason!, comment: _comment.text.trim());
    if (_block) await api.block(widget.person.userId);
    if (!mounted) return;
    showInfo(
      context,
      urgent
          ? 'Жалоба принята. Модератор посмотрит её в первую очередь.'
          : 'Жалоба принята. Спасибо, что помогаете держать «Своих» чистыми.',
    );
    Navigator.of(context).pop(_block);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Пожаловаться', style: t.headlineSmall),
            const SizedBox(height: 6),
            Text('${widget.person.name} не узнает, кто пожаловался.', style: t.bodySmall),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: _reason,
              onChanged: (v) => setState(() => _reason = v),
              child: Column(
                children: [
                  for (final (id, label) in reportReasons)
                    RadioListTile<String>(
                      key: Key('reason-$id'),
                      value: id,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(label, style: t.bodyLarge),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _comment,
              maxLines: 3,
              maxLength: 1000,
              decoration: const InputDecoration(hintText: 'Что случилось? (необязательно)'),
            ),
            CheckboxListTile(
              value: _block,
              onChanged: (v) => setState(() => _block = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Заодно заблокировать'),
            ),
            const SizedBox(height: 8),
            BusyButton(label: 'Отправить жалобу', onPressed: _reason == null ? null : _send),
          ],
        ),
      ),
    );
  }
}

/// Подтверждение действия. Возвращает true, если человек согласился.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String text,
  required String ok,
}) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontSize: 18)),
      content: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.error),
          child: Text(ok),
        ),
      ],
    ),
  );
  return res ?? false;
}
