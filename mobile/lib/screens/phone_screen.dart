import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app.dart';
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

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
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
      button: BusyButton(
        label: 'Получить звонок',
        onPressed: _valid ? () => AppScope.read(context).requestCode('+7$_digits') : null,
      ),
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
            decoration: const InputDecoration(
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
          if (state.api.isDemo) ...[
            const SizedBox(height: 16),
            const DemoBanner(text: 'Демо-режим: звонка не будет, код всегда 1234. Люди в ленте ненастоящие.'),
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
