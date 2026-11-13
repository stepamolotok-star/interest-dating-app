import 'package:flutter/foundation.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:material_ui/material_ui.dart';

import 'api/api.dart';
import 'api/demo_api.dart';
import 'api/http_api.dart';
import 'app.dart';
import 'state.dart';

/// Адрес сервера задаётся при сборке: --dart-define=API_URL=https://...
/// Без него приложение запускается в демо-режиме.
const apiUrl = String.fromEnvironment('API_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _highRefreshRate();
  final Api api = apiUrl.isEmpty ? DemoApi() : HttpApi(apiUrl);
  runApp(SvoiApp(state: AppState(api)..start()));
}

/// Многие Android-телефоны (особенно Xiaomi, Realme, Poco) держат сторонние приложения
/// на 60 Гц, пока приложение само не попросит больше. Просим максимальную частоту экрана
/// при том же разрешении — 90/120/144 Гц, если телефон умеет. На iPhone с ProMotion
/// это включено в Info.plist (CADisableMinimumFrameDurationOnPhone).
Future<void> _highRefreshRate() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (_) {
    // Старый Android или телефон без выбора частоты — работаем как есть.
  }
}
