import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../contacts.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/safety.dart' show confirm;
import 'goals_screen.dart';
import 'interests_screen.dart';
import 'profile_edit_screen.dart';

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
          const _ProfileSummary(),
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
          const _HideFromContacts(),
          const SizedBox(height: 16),
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

/// «Скрыть меня от моих контактов»: люди из записной книжки не увидят вас
/// ни в ленте, ни в «Рядом».
class _HideFromContacts extends StatefulWidget {
  const _HideFromContacts();

  @override
  State<_HideFromContacts> createState() => _HideFromContactsState();
}

class _HideFromContactsState extends State<_HideFromContacts> {
  ContactsStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final st = await AppScope.read(context).api.contactsStatus();
      if (mounted) setState(() => _status = st);
    } catch (_) {
      // Покажем переключатель выключенным; ошибка всплывёт при попытке включить.
      if (mounted) setState(() => _status = const ContactsStatus());
    }
  }

  Future<void> _upload() async {
    final state = AppScope.read(context);
    final numbers = await state.contacts.phoneNumbers();
    final st = await state.api.uploadContacts(hashContacts(numbers));
    if (!mounted) return;
    setState(() => _status = st);
    showInfo(
      context,
      st.count == 0 ? 'В контактах нет российских мобильных номеров' : 'Учли номеров: ${st.count}',
    );
  }

  Future<void> _toggle(bool on) async {
    if (on &&
        !await confirm(
          context,
          title: 'Скрыть вас от ваших контактов?',
          text:
              'Мы прочитаем номера из записной книжки и отправим их только в виде хешей — ни имён, ни самих '
              'номеров. Люди с этими номерами не увидят вас ни в ленте, ни в «Рядом». Выключите — и всё удалим.',
          ok: 'Скрыть',
        )) {
      return;
    }
    if (!mounted) return;
    final api = AppScope.read(context).api;
    await _run(() async {
      if (on) {
        await _upload();
      } else {
        await api.clearContacts();
        if (mounted) setState(() => _status = const ContactsStatus());
      }
    });
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
    } on ContactsError catch (e) {
      if (mounted) showInfo(context, e.message);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = _status;
    final t = Theme.of(context).textTheme;
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const Key('hide-from-contacts'),
              contentPadding: EdgeInsets.zero,
              value: st?.hide ?? false,
              onChanged: st == null || _busy ? null : _toggle,
              title: const Text(
                'Скрыть меня от моих контактов',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                st?.hide ?? false
                    ? 'Номеров учтено: ${st!.count}. Эти люди не увидят вас ни в ленте, ни в «Рядом».'
                    : 'Коллеги, бывшие, родственники из записной книжки вас не увидят.',
                style: t.bodySmall,
              ),
            ),
            if (st?.hide ?? false)
              TextButton(
                onPressed: _busy ? null : () => _run(_upload),
                child: const Text('Обновить список контактов'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Анкета в профиле: «о себе» и ответы на вопросы, кнопка «Изменить».
class _ProfileSummary extends StatefulWidget {
  const _ProfileSummary();

  @override
  State<_ProfileSummary> createState() => _ProfileSummaryState();
}

class _ProfileSummaryState extends State<_ProfileSummary> {
  ProfileFields? _f;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final f = await AppScope.read(context).api.profile();
      if (mounted) setState(() => _f = f);
    } catch (_) {
      // Не загрузилось — покажем приглашение заполнить, сохранение всё равно сверит с сервером.
      if (mounted) setState(() => _f = ProfileFields());
    }
  }

  Future<void> _edit() async {
    final saved = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const ProfileEditScreen()));
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final f = _f;
    final t = Theme.of(context).textTheme;
    final empty = f == null || (f.about.isEmpty && f.prompts.isEmpty);
    return _Section(
      title: 'Анкета',
      onEdit: _edit,
      child: f == null
          ? const SizedBox(height: 24)
          : empty
          ? Material(
              color: AppColors.accentTint,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                key: const Key('fill-profile'),
                borderRadius: BorderRadius.circular(16),
                onTap: _edit,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const Icon(Icons.edit_note, color: AppColors.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Расскажите о себе и ответьте на пару вопросов — без этого карточка в ленте почти пустая.',
                          style: t.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (f.about.isNotEmpty)
                  Text(f.about, style: t.bodyLarge, maxLines: 3, overflow: TextOverflow.ellipsis),
                for (final p in f.prompts) ...[
                  const SizedBox(height: 8),
                  Text(p.question, style: t.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
                  Text(p.answer, style: t.bodyMedium),
                ],
              ],
            ),
    );
  }
}
