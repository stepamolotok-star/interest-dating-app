import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Город из справочника (тот же файл, что на сервере: backend/internal/cities/cities.json).
class City {
  const City({required this.id, required this.name, required this.region, this.pop = 0});

  factory City.fromJson(Map<String, dynamic> j) => City(
    id: j['id'] as String,
    name: j['name'] as String,
    region: j['region'] as String? ?? '',
    pop: j['pop'] as int? ?? 0,
  );

  /// Код ФИАС.
  final String id;
  final String name;

  /// Пусто у Москвы, Санкт-Петербурга и Севастополя.
  final String region;
  final int pop;

  /// «Чита, Забайкальский край».
  String get label => region.isEmpty ? name : '$name, $region';
}

/// Справочник городов России: поиск прямо в приложении, без сервера.
class Cities {
  Cities._(this._list);

  final List<City> _list;

  static Cities? _loaded;

  /// [json] — для тестов; иначе файл из ассетов.
  static Future<Cities> load({String? json}) async {
    if (json == null && _loaded != null) return _loaded!;
    // Не loadString: большие файлы он разбирает в отдельном isolate, а нам хватит и так.
    final raw = json ?? utf8.decode((await rootBundle.load('assets/data/cities.json')).buffer.asUint8List());
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final list = (data['cities'] as List).map((e) => City.fromJson(e as Map<String, dynamic>)).toList()
      ..sort((a, b) => b.pop.compareTo(a.pop));
    final c = Cities._(list);
    if (json == null) _loaded = c;
    return c;
  }

  City? byId(String id) {
    for (final c in _list) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Как на сервере: точные совпадения, затем начинающиеся с запроса, затем содержащие;
  /// внутри — крупные города первыми.
  List<City> search(String query, {int limit = 30}) {
    final q = _norm(query);
    if (q.isEmpty) return const [];
    final exact = <City>[], starts = <City>[], contains = <City>[];
    for (final c in _list) {
      final n = _norm(c.name);
      if (n == q) {
        exact.add(c);
      } else if (n.startsWith(q)) {
        starts.add(c);
      } else if (n.contains(q)) {
        contains.add(c);
      }
    }
    return [...exact, ...starts, ...contains].take(limit).toList();
  }
}

String _norm(String s) => s.trim().toLowerCase().replaceAll('ё', 'е');
