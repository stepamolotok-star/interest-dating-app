import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api.dart';
import '../app.dart';
import '../widgets/common.dart';

/// Ввод кода: последние цифры номера звонка или код из SMS.
class CodeScreen extends StatefulWidget {
  const CodeScreen({super.key});

  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends State<CodeScreen> {
  final _ctrl = TextEditingController();
  Timer? _timer;
  int _left = 0;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startTimer(AppScope.read(context).challenge?.resendAfter ?? 60);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _startTimer(int seconds) {
    _timer?.cancel();
    setState(() => _left = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_left <= 1) t.cancel();
      setState(() => _left = _left > 0 ? _left - 1 : 0);
    });
  }

  int get _length => AppScope.read(context).challenge?.codeLength ?? 4;

  void _onChanged() {
    if (_error != null) setState(() => _error = null);
    if (_ctrl.text.length == _length && !_busy) _submit();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await AppScope.read(context).verify(_ctrl.text);
    } on ApiException catch (e) {
      if (!mounted) return;
      // Сначала очищаем поле: очистка сама сбрасывает текст ошибки.
      _ctrl.clear();
      setState(() => _error = e.message.isEmpty ? null : e.message[0].toUpperCase() + e.message.substring(1));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend(String method) async {
    final state = AppScope.read(context);
    try {
      await state.requestCode(state.phone, method: method);
      _ctrl.clear();
      _startTimer(state.challenge?.resendAfter ?? 60);
    } on ApiException catch (e) {
      if (!mounted) return;
      showError(context, e);
      if (e.retryAfter > 0) _startTimer(e.retryAfter);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bySms = state.challenge?.method == 'sms';
    final phone = _pretty(state.phone);
    return StepScaffold(
      step: 1,
      onBack: state.changePhone,
      title: bySms ? 'Код из SMS' : 'Сейчас позвоним',
      subtitle: bySms
          ? 'Отправили SMS на $phone.'
          : 'На $phone поступит звонок и сразу сбросится. '
                'Введите последние $_length цифры номера, с которого звонили.',
      button: _left > 0
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Повторить можно через ${_left ~/ 60}:${(_left % 60).toString().padLeft(2, '0')}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          : Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: () => _resend('call'), child: const Text('Позвонить ещё')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(onPressed: () => _resend('sms'), child: const Text('Прислать SMS')),
                ),
              ],
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('code'),
            controller: _ctrl,
            autofocus: true,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: _length,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: 18),
            decoration: InputDecoration(counterText: '', hintText: '•' * _length, errorText: _error),
          ),
          if (_busy) ...[const SizedBox(height: 16), const Center(child: CircularProgressIndicator())],
          if (state.api.isDemo) ...[
            const SizedBox(height: 16),
            const DemoBanner(text: 'Демо-режим: введите 1234.'),
          ],
          const SizedBox(height: 16),
          TextButton(onPressed: state.changePhone, child: const Text('Изменить номер')),
        ],
      ),
    );
  }
}

String _pretty(String e164) {
  final d = e164.replaceAll(RegExp(r'\D'), '');
  if (d.length != 11) return e164;
  return '+7 ${d.substring(1, 4)} ${d.substring(4, 7)}-${d.substring(7, 9)}-${d.substring(9)}';
}
