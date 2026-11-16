import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'models.dart';

/// Системные уведомления телефона. Отдельный класс — чтобы в тестах подменить.
abstract class Notifier {
  /// [onTap] вызывается с id разговора, когда человек нажал на уведомление.
  Future<void> init(void Function(String matchId) onTap);

  /// Спрашивает разрешение (Android 13+). true — можно показывать.
  Future<bool> requestPermission();

  /// Разрешено ли сейчас.
  Future<bool> enabled();

  Future<void> show(PushEvent e);

  /// Приложение запустили нажатием на уведомление — какой разговор открыть.
  Future<String?> launchMatch();
}

/// Ничего не показывает: тесты и платформы без уведомлений.
class SilentNotifier implements Notifier {
  SilentNotifier();

  final shown = <PushEvent>[];
  bool allowed = true;

  @override
  Future<void> init(void Function(String matchId) onTap) async {}

  @override
  Future<bool> requestPermission() async => allowed;

  @override
  Future<bool> enabled() async => allowed;

  @override
  Future<void> show(PushEvent e) async {
    if (allowed) shown.add(e);
  }

  @override
  Future<String?> launchMatch() async => null;
}

/// Уведомления Android через flutter_local_notifications. Их показывает само приложение:
/// в демо — о своих событиях, с сервером — о push, пришедших, пока приложение открыто.
class LocalNotifier implements Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  /// Тот же канал, что указывает сервер в push (notify.channelID).
  static const channel = AndroidNotificationChannel(
    'svoi_default',
    'Взаимный интерес и сообщения',
    description: 'Новые совпадения, сообщения и люди рядом',
    importance: Importance.high,
  );

  var _id = 0;

  @override
  Future<void> init(void Function(String matchId) onTap) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_svoi')),
      onDidReceiveNotificationResponse: (r) {
        final id = r.payload ?? '';
        if (id.isNotEmpty) onTap(id);
      },
    );
    await _android?.createNotificationChannel(channel);
  }

  @override
  Future<bool> requestPermission() async => await _android?.requestNotificationsPermission() ?? false;

  @override
  Future<bool> enabled() async => await _android?.areNotificationsEnabled() ?? false;

  @override
  Future<void> show(PushEvent e) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _plugin.show(
      // Сообщения одного разговора заменяют друг друга, а не копятся пачкой.
      id: e.matchId.isEmpty ? 1000 + _id++ : e.matchId.hashCode & 0x7fffffff,
      title: e.title,
      body: e.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: Importance.high,
          priority: Priority.high,
          color: const Color(0xFF0E7A6A),
          // Текст не показываем на экране блокировки, если человек не разрешил подробности.
          visibility: e.private ? NotificationVisibility.private : NotificationVisibility.public,
        ),
      ),
      payload: e.matchId,
    );
  }

  @override
  Future<String?> launchMatch() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    final d = await _plugin.getNotificationAppLaunchDetails();
    final id = d?.notificationResponse?.payload ?? '';
    return (d?.didNotificationLaunchApp ?? false) && id.isNotEmpty ? id : null;
  }
}
