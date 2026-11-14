import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Вход: российский мобильный номер, код придёт звонком-сбросом.
class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  final _ctrl = TextEditingController();
  List<AuthProvider> _providers = const [];
  String? _busyProvider;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
    Future.microtask(_loadProviders);
  }

  Future<void> _loadProviders() async {
    try {
      final list = await AppScope.read(context).api.authProviders();
      if (mounted) setState(() => _providers = list);
    } catch (_) {
      // Нет связи — остаётся вход по номеру.
    }
  }

  static const _askedKey = 'autofill_call_asked';

  /// Перед первым звонком на Android предлагаем подставлять код самим.
  /// Спрашиваем один раз; отказ — просто вводите цифры вручную.
  Future<void> _requestCall() async {
    final state = AppScope.read(context);
    final autofill = state.autofill;
    final prefs = await SharedPreferences.getInstance();
    if (autofill.supportsCall && !await autofill.hasCallPermission() && !(prefs.getBool(_askedKey) ?? false)) {
      await prefs.setBool(_askedKey, true);
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Подставить код автоматически?'),
          content: const Text(
            'Код — последние 4 цифры номера, который вам позвонит. Чтобы не вводить их вручную, '
            'разрешите приложению видеть номер входящего звонка. Мы смотрим только этот один звонок, '
            'журнал звонков не читаем и ничего не сохраняем.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Введу сам')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Разрешить')),
          ],
        ),
      );
      if (ok == true) await autofill.requestCallPermission();
    }
    await state.requestCode('+7$_digits');
  }

  Future<void> _loginWith(AuthProvider p) async {
    setState(() => _busyProvider = p.id);
    try {
      await AppScope.read(context).loginWith(p.id);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busyProvider = null);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String get _digits => _ctrl.text.replaceAll(RegExp(r'\D'), '');
  bool get _valid => _digits.length == 10 && _digits.startsWith('9');

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return StepScaffold(
      step: 1,
      title: 'Найди своих людей по интересам',
      subtitle: 'Войдите по номеру телефона. Регистрация займёт пару минут.',
      button: BusyButton(label: 'Получить звонок', onPressed: _valid ? _requestCall : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('phone'),
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.phone,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 0.5),
            inputFormatters: [_PhoneFormatter()],
            decoration: InputDecoration(
              prefixText: '+7 ',
              prefixStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.ink),
              hintText: '900 000-00-00',
            ),
          ),
          const SizedBox(height: 16),
          const _Note(
            icon: Icons.phone_callback_outlined,
            text:
                'Мы позвоним и сразу сбросим — отвечать не нужно. '
                'Код — последние 4 цифры номера, с которого был звонок.',
          ),
          const SizedBox(height: 10),
          const _Note(
            icon: Icons.lock_outline,
            text:
                'Номер никто не увидит. Он нужен только для входа: по закону '
                'регистрироваться можно лишь с российским номером.',
          ),
          if (_providers.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                const Expanded(child: Divider()),
                Flexible(
                  flex: 3,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('или через', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                  ),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 14),
            for (final p in _providers)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ProviderButton(
                  provider: p,
                  busy: _busyProvider == p.id,
                  onPressed: _busyProvider == null ? () => _loginWith(p) : null,
                ),
              ),
            const _Note(
              icon: Icons.verified_user_outlined,
              text:
                  'Из аккаунта нам нужен только номер телефона — чтобы подтвердить его. Больше ничего '
                  'не сохраняем и ничего от вашего имени не публикуем, друзья ничего не увидят.',
            ),
          ],
          if (state.api.isDemo) ...[
            const SizedBox(height: 16),
            const DemoBanner(
              text:
                  'Демо-режим: звонка не будет, код всегда 1234; кнопки VK ID и Яндекс ID сразу пускают внутрь. '
                  'Люди в ленте ненастоящие.',
            ),
          ],
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.accent),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
      ],
    );
  }
}

/// Оставляет 10 цифр после +7 и форматирует как «912 345-67-89».
/// Вставленный номер с 8 или +7 в начале тоже понимает.
class _PhoneFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    var d = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (d.length == 11 && (d.startsWith('7') || d.startsWith('8'))) d = d.substring(1);
    if (d.length > 10) d = d.substring(0, 10);
    final b = StringBuffer();
    for (var i = 0; i < d.length; i++) {
      if (i == 3) b.write(' ');
      if (i == 6 || i == 8) b.write('-');
      b.write(d[i]);
    }
    final text = b.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Кнопка входа через ID-сервис в его фирменном цвете.
class _ProviderButton extends StatelessWidget {
  const _ProviderButton({required this.provider, required this.busy, required this.onPressed});

  final AuthProvider provider;
  final bool busy;
  final VoidCallback? onPressed;

  static const _colors = {'vk': Color(0xFF0077FF), 'yandex': Color(0xFF000000)};

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      key: Key('login-${provider.id}'),
      // Фирменные цвета VK и Яндекса — в обеих темах; текст всегда белый.
      // Чёрная кнопка Яндекса в тёмной теме слилась бы с фоном — даём ей тонкую рамку.
      style: FilledButton.styleFrom(
        backgroundColor: _colors[provider.id] ?? AppColors.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: (_colors[provider.id] ?? AppColors.accent).withValues(alpha: 0.5),
        disabledForegroundColor: Colors.white,
        side: AppColors.dark && provider.id == 'yandex' ? const BorderSide(color: Color(0x40FFFFFF)) : null,
      ),
      onPressed: onPressed,
      child: busy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
            )
          : Text('Войти через ${provider.name}'),
    );
  }
}
