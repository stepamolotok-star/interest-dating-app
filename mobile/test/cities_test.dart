import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:svoi/cities.dart';

void main() {
  test('справочник городов: регион различает одноимённые города', () async {
    final c = await Cities.load(json: File('assets/data/cities.json').readAsStringSync());
    final chita = c.search('чита').first;
    expect(chita.label, 'Чита, Забайкальский край');
    final sovetsk = c.search('Советск').where((x) => x.name == 'Советск').toList();
    expect(sovetsk.length, greaterThan(1));
    expect(sovetsk.map((x) => x.region).toSet().length, sovetsk.length, reason: 'у всех разные регионы');
    expect(c.search('мо').first.name, 'Москва');
    expect(c.search('орел').first.name, 'Орёл');
    expect(c.search('такого нет'), isEmpty);
  });

  test('файл городов в приложении совпадает с серверным', () {
    expect(
      File('assets/data/cities.json').readAsStringSync(),
      File('../backend/internal/cities/cities.json').readAsStringSync(),
    );
  });
}
