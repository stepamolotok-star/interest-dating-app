import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../widgets/common.dart';
import '../widgets/profile_blocks.dart';

/// Правка анкеты: один блок (нажали на строку в профиле) или несколько сразу.
/// У каждого блока своя видимость: все в ленте / после взаимного интереса / только для подбора / никто.
class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key, this.blocks = ProfileBlock.values});

  final List<ProfileBlock> blocks;

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
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

  Future<void> _save() async {
    final state = AppScope.read(context);
    final f = await _draft!.save(state.api);
    state.setProfile(f);
    if (!mounted) return;
    showInfo(context, 'Сохранено');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final d = _draft;
    final title = widget.blocks.length == 1 ? widget.blocks.single.title : 'Анкета';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: d == null
          ? Center(
              child: _loadError == null
                  ? const CircularProgressIndicator()
                  : TextButton(onPressed: _load, child: const Text('Не загрузилось. Повторить')),
            )
          : SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      children: [ProfileBlocksForm(draft: d, blocks: widget.blocks)],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: BusyButton(label: 'Сохранить', onPressed: _save),
                  ),
                ],
              ),
            ),
    );
  }
}
