import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../location.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/safety.dart';
import 'nearby_tab.dart' show radiusLabel;

const _radii = [300, 1000, 3000, 10000];

/// Выбор видимости: насколько и для кого. Возвращает новые настройки или null.
Future<NearbyVisibility?> showVisibilitySheet(BuildContext context, {NearbyVisibility? current}) {
  return showModalBottomSheet<NearbyVisibility>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.bg,
    builder: (_) => _VisibilitySheet(current: current),
  );
}

class _VisibilitySheet extends StatefulWidget {
  const _VisibilitySheet({this.current});

  final NearbyVisibility? current;

  @override
  State<_VisibilitySheet> createState() => _VisibilitySheetState();
}

class _VisibilitySheetState extends State<_VisibilitySheet> {
  /// 0 — пока открыто приложение, иначе число часов.
  int _hours = 1;
  late int _radius = widget.current?.radiusM ?? 1000;
  late bool _verifiedOnly = widget.current?.verifiedOnly ?? false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Видимость рядом', style: t.headlineSmall),
            const SizedBox(height: 16),
            Text('Как долго', style: t.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (h, label) in const [
                  (1, '1 час'),
                  (3, '3 часа'),
                  (8, '8 часов'),
                  (0, 'Пока открыто приложение'),
                ])
                  ChoiceChip(
                    key: Key('hours-$h'),
                    label: Text(label),
                    selected: _hours == h,
                    showCheckmark: false,
                    selectedColor: AppColors.accentTint,
                    onSelected: (_) => setState(() => _hours = h),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text('Радиус', style: t.titleMedium),
            const SizedBox(height: 4),
            Text('Видите вы и видят вас только в пределах меньшего из двух радиусов.', style: t.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final r in _radii)
                  ChoiceChip(
                    label: Text(radiusLabel(r)),
                    selected: _radius == r,
                    showCheckmark: false,
                    selectedColor: AppColors.accentTint,
                    onSelected: (_) => setState(() => _radius = r),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _verifiedOnly,
              onChanged: (v) => setState(() => _verifiedOnly = v),
              title: const Text('Только подтверждённым', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Вас увидят только те, кто подтвердил возраст или фото'),
            ),
            const SizedBox(height: 12),
            BusyButton(
              label: 'Включить видимость',
              color: AppColors.accent,
              onPressed: () async {
                final v = await AppScope.read(context).api.setVisibility(
                  mode: _hours == 0 ? 'foreground' : 'timed',
                  hours: _hours,
                  radiusM: _radius,
                  verifiedOnly: _verifiedOnly,
                );
                if (context.mounted) Navigator.of(context).pop(v);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Настройки «Рядом»: видимость и личные зоны.
class NearbySettingsScreen extends StatefulWidget {
  const NearbySettingsScreen({super.key});

  @override
  State<NearbySettingsScreen> createState() => _NearbySettingsScreenState();
}

class _NearbySettingsScreenState extends State<NearbySettingsScreen> {
  NearbyVisibility? _vis;
  List<Zone>? _zones;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    final api = AppScope.read(context).api;
    try {
      final v = await api.visibility();
      final z = await api.zones();
      if (mounted) {
        setState(() {
          _vis = v;
          _zones = z;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _addZone() async {
    final created = await showModalBottomSheet<Zone>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.bg,
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: const _ZoneSheet(),
      ),
    );
    if (created != null && mounted) setState(() => _zones = [...?_zones, created]);
  }

  Future<void> _deleteZone(Zone z) async {
    if (!await confirm(
      context,
      title: 'Удалить зону «${z.name}»?',
      text: 'Там вас снова смогут увидеть, когда видимость включена.',
      ok: 'Удалить',
    )) {
      return;
    }
    if (!mounted) return;
    try {
      await AppScope.read(context).api.deleteZone(z.id);
      if (mounted) setState(() => _zones!.remove(z));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _toggle(bool on) async {
    final api = AppScope.read(context).api;
    if (on) {
      final v = await showVisibilitySheet(context, current: _vis);
      if (v != null && mounted) setState(() => _vis = v);
      return;
    }
    try {
      await api.disappear();
      final v = await api.visibility();
      if (mounted) setState(() => _vis = v);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final v = _vis;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки «Рядом»')),
      body: v == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                SwitchListTile(
                  key: const Key('visibility-switch'),
                  contentPadding: EdgeInsets.zero,
                  value: v.active,
                  onChanged: _toggle,
                  title: const Text('Меня видно', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                  subtitle: Text(
                    v.active
                        ? 'Радиус ${radiusLabel(v.radiusM)}${v.verifiedOnly ? ' · только подтверждённым' : ''}'
                        : 'Вас никто не видит, и вы не видите других',
                  ),
                ),
                const Divider(height: 32),
                Text('Личные зоны', style: t.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'В этих местах вас не видно, даже если видимость включена. Например, дом и работа — '
                  'чтобы никто не мог вычислить, где вы живёте.',
                  style: t.bodySmall,
                ),
                const SizedBox(height: 8),
                if (_zones != null)
                  for (final z in _zones!)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.shield_moon_outlined, color: AppColors.accent),
                      title: Text(z.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('Радиус ${radiusLabel(z.radiusM)}'),
                      trailing: IconButton(
                        tooltip: 'Удалить',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteZone(z),
                      ),
                    ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('add-zone'),
                  onPressed: (_zones?.length ?? 0) >= 10 ? null : _addZone,
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: const Text('Добавить зону там, где я сейчас'),
                ),
                const SizedBox(height: 24),
                Text('Как мы бережём ваше место', style: t.titleMedium),
                const SizedBox(height: 8),
                Text(
                  '• Точные координаты не хранятся: сервер сразу округляет их до квартала (~150 м) '
                  'и забывает через 10 минут. Истории перемещений нет.\n'
                  '• Другим показываем только интервал: «до 500 м», «до 1 км» и т. п. Он не меняется '
                  '15 минут, чтобы нельзя было «сужать круг».\n'
                  '• При подмене GPS «Рядом» отключается на час.',
                  style: t.bodySmall,
                ),
              ],
            ),
    );
  }
}

class _ZoneSheet extends StatefulWidget {
  const _ZoneSheet();

  @override
  State<_ZoneSheet> createState() => _ZoneSheetState();
}

class _ZoneSheetState extends State<_ZoneSheet> {
  final _name = TextEditingController(text: 'Дом');
  int _radius = 500;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = AppScope.read(context);
    Fix fix;
    try {
      fix = await state.location.current();
    } on LocationError catch (e) {
      if (mounted) showInfo(context, e.message);
      return;
    }
    final z = await state.api.addZone(_name.text.trim(), fix.lat, fix.lon, _radius);
    if (mounted) Navigator.of(context).pop(z);
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
            Text('Личная зона', style: t.headlineSmall),
            const SizedBox(height: 6),
            Text('Отметим круг вокруг места, где вы сейчас.', style: t.bodySmall),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                for (final n in const ['Дом', 'Работа', 'Учёба', 'Родители'])
                  ActionChip(label: Text(n), onPressed: () => _name.text = n),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('zone-name'),
              controller: _name,
              maxLength: 30,
              decoration: const InputDecoration(labelText: 'Название', counterText: ''),
            ),
            const SizedBox(height: 16),
            Text('Радиус', style: t.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final r in const [500, 1000, 2000])
                  ChoiceChip(
                    label: Text(radiusLabel(r)),
                    selected: _radius == r,
                    showCheckmark: false,
                    selectedColor: AppColors.accentTint,
                    onSelected: (_) => setState(() => _radius = r),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            BusyButton(
              label: 'Сохранить зону',
              color: AppColors.accent,
              onPressed: _name.text.trim().isEmpty ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}
