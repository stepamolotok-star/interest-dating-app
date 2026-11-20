import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api.dart';
import '../app.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Проверка фото по селфи: повторить жест, снять себя фронтальной камерой, отправить.
/// Модератор сравнит лицо с фото анкеты; подтвердит — у анкеты значок «Фото проверено».
class VerifyScreen extends StatefulWidget {
  const VerifyScreen({super.key});

  /// Съёмка селфи; в тестах подменяется.
  static Future<Uint8List?> Function() takeSelfie = _camera;

  static Future<Uint8List?> _camera() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.front,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
    );
    return file?.readAsBytes();
  }

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  Uint8List? _selfie;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_start);
  }

  Future<void> _start() async {
    try {
      await AppScope.read(context).startVerification();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Не получилось начать проверку. Проверьте интернет и попробуйте ещё раз.');
    }
  }

  Future<void> _shoot() async {
    try {
      final bytes = await VerifyScreen.takeSelfie();
      if (bytes != null && mounted) setState(() => _selfie = bytes);
    } catch (_) {
      if (mounted) {
        showError(context, const ApiException(0, 'Не получилось открыть камеру. Проверьте доступ к камере.'));
      }
    }
  }

  Future<void> _send() async {
    final bytes = _selfie;
    if (bytes == null) return;
    final state = AppScope.read(context);
    try {
      await state.submitSelfie(bytes);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Селфи отправлено — пришлём уведомление, когда модератор проверит')));
  }

  @override
  Widget build(BuildContext context) {
    final v = AppScope.of(context).verification;
    final t = Theme.of(context).textTheme;
    final selfie = _selfie;
    final ready = v.status == 'requested' && v.gesture.isNotEmpty;
    return StepScaffold(
      title: 'Проверка фото',
      subtitle:
          'Сделайте селфи с жестом — модератор сравнит его с фото анкеты. '
          'Селфи увидит только он, после проверки оно удаляется.',
      onBack: () => Navigator.pop(context),
      button: selfie == null
          ? FilledButton.icon(
              key: const Key('take-selfie'),
              onPressed: ready ? _shoot : null,
              icon: const Icon(Icons.photo_camera_front_outlined),
              label: const Text('Сделать селфи'),
            )
          : BusyButton(key: const Key('send-selfie'), label: 'Отправить на проверку', onPressed: _send),
      secondary: selfie == null
          ? null
          : TextButton(key: const Key('retake-selfie'), onPressed: _shoot, child: const Text('Переснять')),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null)
            Text(
              _error!,
              key: const Key('verify-error'),
              style: t.bodyLarge?.copyWith(color: AppColors.error),
            )
          else if (!ready)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            Container(
              key: const Key('gesture'),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.accentTint,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.accent),
              ),
              child: Row(
                children: [
                  Icon(Icons.back_hand_outlined, size: 36, color: AppColors.accent),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Жест на селфи', style: t.labelLarge?.copyWith(color: AppColors.accent)),
                        const SizedBox(height: 4),
                        Text(v.gesture, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (selfie != null)
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Image.memory(selfie, key: const Key('selfie-preview'), height: 300, fit: BoxFit.cover),
                ),
              )
            else
              for (final tip in const [
                'Лицо целиком и хорошо освещено',
                'Без маски и тёмных очков',
                'Только вы в кадре — снимок, а не фото экрана',
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline, size: 20, color: AppColors.accent),
                      const SizedBox(width: 10),
                      Expanded(child: Text(tip, style: t.bodyLarge)),
                    ],
                  ),
                ),
          ],
        ],
      ),
    );
  }
}
