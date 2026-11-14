import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/profile_blocks.dart';

/// Последний шаг регистрации: анкета на одном экране. Всё необязательно —
/// можно пропустить и заполнить потом в профиле (там напомним).
class ProfileStepScreen extends StatefulWidget {
  const ProfileStepScreen({super.key});

  /// Религию при регистрации не спрашиваем: для неё нужно отдельное согласие, это — в профиле.
  static const blocks = completionBlocks;

  @override
  State<ProfileStepScreen> createState() => _ProfileStepScreenState();
}

class _ProfileStepScreenState extends State<ProfileStepScreen> {
  ProfileDraft? _draft;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _draft?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final api = AppScope.read(context).api;
      final f = await api.profile();
      final v = await api.fieldVisibility();
      if (mounted) setState(() => _draft = ProfileDraft(f, v));
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  Future<void> _done() async {
    final state = AppScope.read(context);
    final d = _draft;
    if (d != null) state.setProfile(await d.save(state.api));
    await state.finishOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    final d = _draft;
    return StepScaffold(
      step: 5,
      onBack: () => AppScope.read(context).backToInterests(),
      title: 'Немного о себе',
      subtitle: 'Всё необязательно, но с анкетой подбор точнее, а людям проще начать разговор.',
      button: BusyButton(label: 'Готово — к людям', onPressed: d == null ? null : _done),
      secondary: TextButton(
        key: const Key('skip-profile'),
        onPressed: () => AppScope.read(context).finishOnboarding(),
        child: Text('Пропустить, заполню потом', style: TextStyle(color: AppColors.muted)),
      ),
      child: d == null
          ? Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Center(
                child: _loadError == null
                    ? const CircularProgressIndicator()
                    : TextButton(onPressed: _load, child: const Text('Не загрузилось. Повторить')),
              ),
            )
          : ProfileBlocksForm(draft: d, blocks: ProfileStepScreen.blocks),
    );
  }
}
