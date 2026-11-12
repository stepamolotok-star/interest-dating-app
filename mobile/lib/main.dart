import 'package:material_ui/material_ui.dart';

import 'api/api.dart';
import 'api/demo_api.dart';
import 'api/http_api.dart';
import 'app.dart';
import 'state.dart';

/// Адрес сервера задаётся при сборке: --dart-define=API_URL=https://...
/// Без него приложение запускается в демо-режиме.
const apiUrl = String.fromEnvironment('API_URL');

void main() {
  final Api api = apiUrl.isEmpty ? DemoApi() : HttpApi(apiUrl);
  runApp(SvoiApp(state: AppState(api)..start()));
}
