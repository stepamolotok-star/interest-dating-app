import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../contacts.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/profile_blocks.dart';
import '../widgets/safety.dart' show confirm;
import 'goals_screen.dart';
import 'interests_screen.dart';
import 'nearby_settings_screen.dart';
import 'profile_edit_screen.dart';
import 'profile_preview_screen.dart';

/// Профиль: заполненность и анкета по блокам, цели, интересы, приватность, поддержка, выход.
class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  @override
  void initState() {
    super.initState();
    final state = AppScope.read(context);
    if (state.profile == null) Future.microtask(state.loadProfile);
  }

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
            Text(
              me.region.isEmpty ? me.city : '${me.city}, ${me.region}',
              style: t.bodyLarge?.copyWith(color: AppColors.muted),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (me?.ageVerified ?? false)
                Tag('Возраст подтверждён', icon: Icons.verified_outlined, color: AppColors.accent)
              else
                const Tag('Возраст не подтверждён', icon: Icons.info_outline),
            ],
          ),
          const SizedBox(height: 20),
          const _Completion(),
          const SizedBox(height: 24),
          const _ProfileBlocks(),
          _Section(
            title: 'Цели',
            onEdit: () => openScreen(context, const GoalsScreen()),
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
            onEdit: () => openScreen(context, const InterestsScreen()),
            child: state.interests.isEmpty
                ? _Nudge(
                    key: const Key('add-interests'),
                    icon: Icons.interests_outlined,
                    text: 'Интересы не выбраны — без них подбор почти случайный. Выберите хотя бы три.',
                    onTap: () => openScreen(context, const InterestsScreen()),
                  )
                : Wrap(
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
          const _Privacy(),
          const _Appearance(),
          const SizedBox(height: 16),
          _Support(),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: () => AppScope.read(context).logout(), child: const Text('Выйти')),
        ],
      ),
    );
  }
}

Future<void> openScreen(BuildContext context, Widget screen) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.onEdit});

  final String title;
  final VoidCallback? onEdit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 40,
            child: Row(
              children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                if (onEdit != null) TextButton(onPressed: onEdit, child: const Text('Изменить')),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Подсказка-призыв: мягкая плашка в цвете приложения, нажимается целиком.
class _Nudge extends StatelessWidget {
  const _Nudge({super.key, required this.icon, required this.text, required this.onTap});

  final IconData icon;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accentTint,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon, color: AppColors.accent),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
              Icon(Icons.chevron_right, color: AppColors.accent),
            ],
          ),
        ),
      ),
    );
  }
}

/// Заполненность анкеты и «Как меня видят другие».
class _Completion extends StatelessWidget {
  const _Completion();

  @override
  Widget build(BuildContext context) {
    final f = AppScope.of(context).profile;
    final t = Theme.of(context).textTheme;
    final pct = f == null ? null : profileCompletion(f);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pct != null && pct < 100) ...[
            Text('Анкета заполнена на $pct%', key: const Key('completion'), style: t.titleMedium),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct / 100,
                minHeight: 8,
                color: AppColors.accent,
                backgroundColor: AppColors.accentTint,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Чем полнее анкета, тем точнее подбор и тем проще людям начать с вами разговор.',
              style: t.bodySmall,
            ),
          ] else if (pct == 100)
            Row(
              children: [
                Icon(Icons.check_circle, color: AppColors.accent, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('Анкета заполнена', style: t.titleMedium)),
              ],
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('preview'),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => openScreen(context, const ProfilePreviewScreen()),
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Как меня видят другие'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Анкета блоками: в каждой строке видно, что заполнено; нажатие — правка этого блока.
class _ProfileBlocks extends StatelessWidget {
  const _ProfileBlocks();

  Future<void> _edit(BuildContext context, ProfileBlock b) =>
      openScreen(context, ProfileEditScreen(blocks: [b]));

  @override
  Widget build(BuildContext context) {
    final f = AppScope.of(context).profile;
    final t = Theme.of(context).textTheme;
    return _Section(
      title: 'Анкета',
      child: Material(
        color: AppColors.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppColors.line),
        ),
        child: Column(
          children: [
            for (final (i, b) in ProfileBlock.values.indexed) ...[
              if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: AppColors.line),
              _blockRow(context, b, f == null ? null : blockSummary(b, f), t),
            ],
          ],
        ),
      ),
    );
  }

  Widget _blockRow(BuildContext context, ProfileBlock b, String? summary, TextTheme t) {
    return InkWell(
      key: Key('block-${b.name}'),
      onTap: () => _edit(context, b),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(b.title, style: t.titleMedium),
                  const SizedBox(height: 2),
                  if (summary != null)
                    Text(summary, style: t.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis)
                  else
                    Text(
                      b == ProfileBlock.religion ? 'Не указана' : 'Не заполнено — добавить',
                      style: t.bodyMedium?.copyWith(
                        color: b == ProfileBlock.religion ? AppColors.muted : AppColors.accent,
                        fontWeight: b == ProfileBlock.religion ? null : FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}

/// Оформление: тема как в телефоне, светлая или тёмная.
class _Appearance extends StatelessWidget {
  const _Appearance();

  static const _modes = {
    ThemeMode.system: 'Как в телефоне',
    ThemeMode.light: 'Светлая',
    ThemeMode.dark: 'Тёмная',
  };

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return _Section(
      title: 'Оформление',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final MapEntry(key: mode, value: label) in _modes.entries)
            ChoiceChip(
              key: Key('theme-${mode.name}'),
              label: Text(label),
              selected: state.themeMode == mode,
              showCheckmark: false,
              selectedColor: AppColors.accentTint,
              onSelected: (_) => state.setThemeMode(mode),
            ),
        ],
      ),
    );
  }
}

/// Кто что видит: фото, возраст, знак зодиака, контакты, «Рядом».
/// Переключатели сохраняются сразу.
class _Privacy extends StatefulWidget {
  const _Privacy();

  @override
  State<_Privacy> createState() => _PrivacyState();
}

class _PrivacyState extends State<_Privacy> {
  Map<String, String>? _vis;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final v = await AppScope.read(context).api.fieldVisibility();
      if (mounted) setState(() => _vis = v);
    } catch (_) {
      if (mounted) setState(() => _vis = {});
    }
  }

  Future<void> _photos(bool afterMatch) async {
    final api = AppScope.read(context).api;
    final v = afterMatch ? 'after_match' : 'anonymous';
    setState(() => _vis = {...?_vis, 'photos': v});
    try {
      await api.setFieldVisibility({'photos': v});
    } catch (e) {
      if (mounted) showError(context, e);
      await _load();
    }
  }

  Future<void> _profileFlag(void Function(ProfileFields f) change) async {
    final state = AppScope.read(context);
    final f = state.profile;
    if (f == null) return;
    change(f);
    state.setProfile(f);
    try {
      await state.api.updateProfile(f);
    } catch (e) {
      if (mounted) showError(context, e);
      await state.loadProfile();
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = AppScope.of(context).profile;
    final t = Theme.of(context).textTheme;
    return _Section(
      title: 'Приватность',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Card(
            children: [
              SwitchListTile(
                key: const Key('photos-after-match'),
                contentPadding: EdgeInsets.zero,
                value: _vis?['photos'] == 'after_match',
                onChanged: _vis == null ? null : _photos,
                title: const Text(
                  'Фото только после взаимного интереса',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  'До этого вместо ваших фото — силуэт с замком. Но и чужие фото вы увидите только после '
                  'взаимного интереса — правило одно для всех. В «Рядом» и «Без обязательств» фото до '
                  'взаимности скрыто всегда.',
                  style: t.bodySmall,
                ),
              ),
              Divider(height: 1, color: AppColors.line),
              SwitchListTile(
                key: const Key('age-as-range'),
                contentPadding: EdgeInsets.zero,
                value: f?.ageAsRange ?? false,
                onChanged: f == null ? null : (v) => _profileFlag((f) => f.ageAsRange = v),
                title: const Text('Возраст диапазоном', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                  '«28–32» вместо «30 лет». Фильтры по возрасту работают как обычно.',
                  style: t.bodySmall,
                ),
              ),
              Divider(height: 1, color: AppColors.line),
              SwitchListTile(
                key: const Key('show-zodiac'),
                contentPadding: EdgeInsets.zero,
                value: f?.showZodiac ?? false,
                onChanged: f == null ? null : (v) => _profileFlag((f) => f.showZodiac = v),
                title: const Text('Показывать знак зодиака', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('Считаем по дате рождения, саму дату никто не видит.', style: t.bodySmall),
              ),
              Divider(height: 1, color: AppColors.line),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Видимость в «Рядом»', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('Кому и на каком расстоянии вас показывать, личные зоны.', style: t.bodySmall),
                trailing: Icon(Icons.chevron_right, color: AppColors.muted),
                onTap: () => openScreen(context, const NearbySettingsScreen()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _HideFromContacts(),
          const SizedBox(height: 8),
          Text(
            'Кто видит каждый блок анкеты, настраивается внутри блока — значок с глазом.',
            style: t.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.surface,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: AppColors.line),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    ),
  );
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
            style: FilledButton.styleFrom(backgroundColor: AppColors.fill),
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
        side: BorderSide(color: AppColors.line),
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
