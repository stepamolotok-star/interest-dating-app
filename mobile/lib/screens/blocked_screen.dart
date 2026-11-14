import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'chat_screen.dart' show dayLabel;

/// Аккаунт заблокирован модератором — навсегда или на срок.
class BlockedScreen extends StatefulWidget {
  const BlockedScreen({super.key});

  @override
  State<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends State<BlockedScreen> {
  bool _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await AppScope.read(context).retryBlocked();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final until = state.block?.until;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            Icon(Icons.block, size: 48, color: AppColors.error),
            const SizedBox(height: 16),
            Text(until == null ? 'Аккаунт заблокирован' : 'Аккаунт временно заблокирован', style: text.headlineMedium),
            const SizedBox(height: 12),
            Text(
              until == null
                  ? 'Модератор проверил жалобы и заблокировал аккаунт за нарушение правил. '
                        'Анкету больше никто не видит, переписки закрыты.'
                  : 'Модератор проверил жалобы и закрыл доступ на время. '
                        'Пока блокировка действует, анкету никто не видит.',
              style: text.bodyLarge,
            ),
            if (until != null) ...[
              const SizedBox(height: 12),
              Text(
                'Доступ вернётся ${dayLabel(until).toLowerCase()} в '
                '${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')}',
                style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Если считаете, что это ошибка, напишите в поддержку — модератор посмотрит ещё раз.',
              style: text.bodyMedium?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 32),
            if (until != null) ...[
              FilledButton(
                onPressed: _busy ? null : _retry,
                child: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Проверить ещё раз'),
              ),
              const SizedBox(height: 8),
            ],
            OutlinedButton(onPressed: _busy ? null : state.logout, child: const Text('Выйти')),
          ],
        ),
      ),
    );
  }
}

/// Предупреждение модератора: показываем один раз, потом сервер его забывает.
Future<void> showModeratorWarning(BuildContext context, String warning) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: Icon(Icons.report_outlined, color: AppColors.error),
      title: const Text('Предупреждение'),
      content: Text(warning),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Понятно'))],
    ),
  );
}
