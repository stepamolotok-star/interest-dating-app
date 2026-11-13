import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:phone_state/phone_state.dart';

/// Автоподстановка кода входа.
///
/// - Звонок-сброс (только Android): с разрешения смотрим номер входящего звонка
///   и берём его последние цифры. Журнал звонков не читаем и ничего не сохраняем.
/// - SMS: поле кода помечено как oneTimeCode — iPhone и автозаполнение Google на Android
///   сами предлагают код из SMS над клавиатурой. Приложение SMS не читает.
/// - iPhone: номер входящего звонка iOS приложениям не отдаёт.
abstract class CodeAutofill {
  /// Умеет ли подставлять код из звонка на этом устройстве.
  bool get supportsCall;

  /// Есть ли уже разрешение видеть номер входящего звонка.
  Future<bool> hasCallPermission();

  /// Просит разрешение (системное окно). true — разрешили.
  Future<bool> requestCallPermission();

  /// Ждёт код: из входящего звонка (method == 'call') или из SMS.
  /// Поток пустой, если на устройстве так нельзя.
  Stream<String> codes({required String method, required int length});
}

/// Последние [length] цифр номера; null — если цифр меньше.
String? lastDigits(String? number, int length) {
  final d = (number ?? '').replaceAll(RegExp(r'\D'), '');
  return d.length < length ? null : d.substring(d.length - length);
}

class DeviceCodeAutofill implements CodeAutofill {
  bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  bool get supportsCall => _android;

  /// Разрешения «Телефон» и «Журнал звонков» — без них Android не отдаёт номер входящего звонка.
  /// Запрос — в MainActivity.kt.
  static const _channel = MethodChannel('ru.svoi/call_permission');

  @override
  Future<bool> hasCallPermission() async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('has') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> requestCallPermission() async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('request') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Stream<String> codes({required String method, required int length}) {
    // Из SMS код подставляет система (автозаполнение над клавиатурой), не приложение.
    if (!_android || method != 'call') return const Stream.empty();
    return _fromCall(length);
  }

  Stream<String> _fromCall(int length) async* {
    if (!await hasCallPermission()) return;
    await for (final s in PhoneState.stream) {
      if (s.status == PhoneStateStatus.CALL_INCOMING) {
        final code = lastDigits(s.number, length);
        if (code != null) yield code;
      }
    }
  }
}

/// Демо-режим: «звонок» приходит через пару секунд, код подставляется сам.
class DemoCodeAutofill implements CodeAutofill {
  const DemoCodeAutofill({this.delay = const Duration(seconds: 2)});

  final Duration delay;

  @override
  bool get supportsCall => true;

  @override
  Future<bool> hasCallPermission() async => true;

  @override
  Future<bool> requestCallPermission() async => true;

  @override
  Stream<String> codes({required String method, required int length}) =>
      Stream.fromFuture(Future.delayed(delay, () => '1234'));
}

/// Без автоподстановки (тесты, веб).
class NoCodeAutofill implements CodeAutofill {
  const NoCodeAutofill();

  @override
  bool get supportsCall => false;

  @override
  Future<bool> hasCallPermission() async => false;

  @override
  Future<bool> requestCallPermission() async => false;

  @override
  Stream<String> codes({required String method, required int length}) => const Stream.empty();
}
