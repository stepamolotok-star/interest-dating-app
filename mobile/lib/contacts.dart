import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

/// Номера из записной книжки для «скрыть меня от контактов».
/// Имена и сами номера никуда не уходят: на сервер отправляется только SHA-256
/// российских мобильных номеров, а сервер хранит их ещё и под секретным ключом.

/// Приводит номер к виду +79XXXXXXXXX. Не российский мобильный — null
/// (зарегистрироваться можно только с таким, остальные нам не нужны).
String? normalizeRuMobile(String raw) {
  var d = raw.replaceAll(RegExp(r'\D'), '');
  if (d.length == 11 && (d.startsWith('7') || d.startsWith('8'))) d = d.substring(1);
  if (d.length != 10 || !d.startsWith('9')) return null;
  return '+7$d';
}

/// SHA-256 номера в hex — то, что уходит на сервер.
String hashPhone(String e164) => sha256.convert(utf8.encode(e164)).toString();

/// Хэши всех подходящих номеров без повторов.
List<String> hashContacts(Iterable<String> rawNumbers) =>
    {for (final n in rawNumbers) ?normalizeRuMobile(n)}.map(hashPhone).toList();

class ContactsError implements Exception {
  const ContactsError(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract class ContactsSource {
  /// Все номера телефонов из записной книжки (как записаны).
  Future<List<String>> phoneNumbers();
}

/// Настоящая записная книжка.
class DeviceContacts implements ContactsSource {
  @override
  Future<List<String>> phoneNumbers() async {
    final status = await FlutterContacts.permissions.request(PermissionType.read);
    if (status != PermissionStatus.granted && status != PermissionStatus.limited) {
      throw const ContactsError('Без доступа к контактам скрыться от них не получится. Разрешите доступ в настройках.');
    }
    final contacts = await FlutterContacts.getAll(properties: {ContactProperty.phone});
    return [
      for (final c in contacts)
        for (final p in c.phones) p.normalizedNumber ?? p.number,
    ];
  }
}

/// Демо-режим: пара выдуманных номеров.
class DemoContacts implements ContactsSource {
  const DemoContacts();

  @override
  Future<List<String>> phoneNumbers() async => const ['8 (914) 123-45-67', '+7 924 000-11-22', '+1 202 555 0100'];
}
