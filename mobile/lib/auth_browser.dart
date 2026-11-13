import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// Открывает страницу входа VK ID / Яндекс ID и ждёт возврата в приложение.
abstract class AuthBrowser {
  /// Возвращает адрес, на который провайдер вернул приложение; null — человек закрыл окно.
  Future<Uri?> open(Uri url, String callbackScheme);
}

class DeviceAuthBrowser implements AuthBrowser {
  @override
  Future<Uri?> open(Uri url, String callbackScheme) async {
    try {
      final result = await FlutterWebAuth2.authenticate(
        url: url.toString(),
        callbackUrlScheme: callbackScheme,
      );
      return Uri.parse(result);
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') return null;
      rethrow;
    }
  }
}

/// Демо-режим: «провайдер» сразу возвращает приложение с кодом.
class DemoAuthBrowser implements AuthBrowser {
  const DemoAuthBrowser();

  @override
  Future<Uri?> open(Uri url, String callbackScheme) async => Uri(
    scheme: callbackScheme,
    host: 'oauth',
    queryParameters: {'code': 'demo', 'state': url.queryParameters['state'], 'device_id': 'demo-device'},
  );
}
