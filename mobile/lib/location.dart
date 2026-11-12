import 'package:geolocator/geolocator.dart';

/// Геопозиция для «Рядом». Точные координаты уходят только на сервер,
/// а он сразу округляет их до ячейки ~150 м и нигде не хранит историю.
class Fix {
  const Fix(this.lat, this.lon, {this.mocked = false});

  final double lat;
  final double lon;

  /// Система сообщила, что включена подмена GPS.
  final bool mocked;
}

/// Ошибка с текстом для человека: геолокация выключена, нет разрешения и т. п.
class LocationError implements Exception {
  const LocationError(this.message, {this.canOpenSettings = false});

  final String message;

  /// Разрешение запрещено навсегда — помочь может только переход в настройки.
  final bool canOpenSettings;

  @override
  String toString() => message;
}

abstract class LocationSource {
  Future<Fix> current();

  /// Открыть настройки приложения (если разрешение запрещено навсегда).
  Future<void> openSettings() async {}
}

/// Настоящая геолокация устройства.
class DeviceLocation implements LocationSource {
  @override
  Future<Fix> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationError('Включите геолокацию на телефоне — без неё «Рядом» не работает.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw const LocationError(
        'Без доступа к геолокации «Рядом» не работает. Разрешите доступ, когда спросим.',
      );
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationError(
        'Доступ к геолокации запрещён в настройках телефона. Разрешите его для «Своих».',
        canOpenSettings: true,
      );
    }
    try {
      // Средней точности хватает: сервер всё равно округлит до ~150 м.
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 20),
        ),
      );
      return Fix(p.latitude, p.longitude, mocked: p.isMocked);
    } on Exception {
      throw const LocationError('Не получилось определить, где вы. Попробуйте ещё раз на улице или у окна.');
    }
  }

  @override
  Future<void> openSettings() => Geolocator.openAppSettings();
}

/// Фиксированная точка — для демо-режима и тестов (центр Читы).
class FixedLocation implements LocationSource {
  const FixedLocation([this.lat = 52.0340, this.lon = 113.4994]);

  final double lat;
  final double lon;

  @override
  Future<Fix> current() async => Fix(lat, lon);

  @override
  Future<void> openSettings() async {}
}
