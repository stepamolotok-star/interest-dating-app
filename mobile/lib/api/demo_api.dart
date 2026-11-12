import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models.dart';
import 'api.dart';

/// Демо-режим: работает без сервера, данные живут в памяти.
/// Код подтверждения всегда [demoCode]. Каталог интересов — тот же, что на сервере.
class DemoApi extends Api {
  DemoApi({this.catalogJson});

  static const demoCode = '1234';

  /// Каталог можно передать строкой (в тестах), иначе он читается из ассетов.
  final String? catalogJson;

  List<_Node>? _nodes;
  bool _registered = false;
  Registration? _reg;
  List<GoalSetting> _goals = [];
  List<MyInterest> _interests = [];
  final _seen = <String>{};
  int _likes = 0;

  @override
  bool get isDemo => true;

  Future<List<_Node>> _catalog() async {
    if (_nodes != null) return _nodes!;
    final raw = catalogJson ?? await rootBundle.loadString('assets/data/catalog.json');
    final data = jsonDecode(raw) as Map<String, dynamic>;
    _nodes = (data['nodes'] as List)
        .cast<Map<String, dynamic>>()
        .map(
          (n) => _Node(
            n['id'] as String,
            n['parent'] as String? ?? '',
            n['name'] as String,
            ((n['synonyms'] as List?) ?? const []).cast<String>(),
          ),
        )
        .toList();
    return _nodes!;
  }

  InterestNode _dto(List<_Node> all, _Node n, {bool withPath = false}) {
    final path = <String>[];
    if (withPath) {
      _Node? cur = n;
      while (cur != null) {
        path.insert(0, cur.name);
        cur = all.where((x) => x.id == cur!.parent).firstOrNull;
      }
    }
    return InterestNode(id: n.id, name: n.name, hasChildren: all.any((x) => x.parent == n.id), path: path);
  }

  Future<void> _pause() => Future<void>.delayed(const Duration(milliseconds: 250));

  void _needSession() {
    if (token == null) throw const ApiException(401, 'войдите заново');
  }

  void _needUser() {
    _needSession();
    if (!_registered) throw const ApiException(403, 'сначала завершите регистрацию');
  }

  @override
  Future<Challenge> startAuth(String phone, {String method = 'call'}) async {
    await _pause();
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 11 || digits[1] != '9') {
      throw const ApiException(400, 'Нужен российский мобильный номер: +7 9XX XXX-XX-XX');
    }
    return Challenge(method: method, codeLength: 4, resendAfter: 60);
  }

  @override
  Future<Session> verify(String phone, String code) async {
    await _pause();
    if (code != demoCode) throw const ApiException(400, 'Неверный код');
    token = 'demo-token';
    return Session(token!, _registered);
  }

  @override
  Future<void> register(Registration r) async {
    _needSession();
    await _pause();
    if (!r.terms || !r.personalData) {
      throw const ApiException(400, 'нужно принять условия и согласие на обработку данных');
    }
    _reg = r;
    _registered = true;
  }

  @override
  Future<void> logout() async {
    token = null;
  }

  @override
  Future<Me> me() async {
    _needUser();
    final r = _reg!;
    final now = DateTime.now();
    var age = now.year - r.birthDate.year;
    if (now.month < r.birthDate.month || (now.month == r.birthDate.month && now.day < r.birthDate.day)) {
      age--;
    }
    return Me(userId: 'demo-me', name: r.name, city: r.city, age: age);
  }

  @override
  Future<List<InterestNode>> categories() async {
    final all = await _catalog();
    return [for (final n in all.where((n) => n.parent.isEmpty)) _dto(all, n)];
  }

  @override
  Future<List<InterestNode>> children(String id) async {
    final all = await _catalog();
    return [for (final n in all.where((n) => n.parent == id)) _dto(all, n)];
  }

  @override
  Future<List<InterestNode>> searchInterests(String query) async {
    final all = await _catalog();
    final q = _norm(query);
    if (q.length < 2) return [];
    final hits = all.where(
      (n) =>
          !all.any((x) => x.parent == n.id) &&
          (_norm(n.name).contains(q) || n.synonyms.any((s) => _norm(s).contains(q))),
    );
    return [for (final n in hits.take(20)) _dto(all, n, withPath: true)];
  }

  @override
  Future<List<GoalSetting>> goals() async {
    _needUser();
    return List.of(_goals);
  }

  @override
  Future<void> setGoals(List<GoalSetting> goals) async {
    _needUser();
    await _pause();
    if (goals.any((g) => g.goal == 'casual')) {
      throw const ApiException(403, 'для этой цели нужно подтвердить возраст через Госуслуги');
    }
    _goals = List.of(goals);
  }

  @override
  Future<List<MyInterest>> interests() async {
    _needUser();
    return [
      for (final i in _interests)
        MyInterest(id: i.id, name: i.name, level: i.level, seekingPartner: i.seekingPartner),
    ];
  }

  @override
  Future<void> setInterests(List<MyInterest> items) async {
    _needUser();
    await _pause();
    final all = await _catalog();
    _interests = [
      for (final i in items)
        MyInterest(
          id: i.id,
          name: all.firstWhere((n) => n.id == i.id).name,
          level: i.level,
          seekingPartner: i.seekingPartner,
        ),
    ];
  }

  @override
  Future<List<FeedCard>> feed(String goal, {int limit = 20}) async {
    _needUser();
    await _pause();
    final all = await _catalog();
    final leaves = all.where((n) => !all.any((x) => x.parent == n.id)).toList();
    final mine = _interests.map((i) => i.id).toList();
    final cards = <FeedCard>[];
    for (var p = 0; p < _people.length; p++) {
      final person = _people[p];
      final id = 'demo-$goal-$p';
      if (_seen.contains(id)) continue;
      // Общие интересы: часть моих, сдвинутая на номер человека, чтобы у всех были разные.
      final count = mine.isEmpty ? 0 : (person.shared).clamp(1, mine.length);
      final shared = <SharedInterest>[
        for (var k = 0; k < count; k++)
          () {
            final iid = mine[(p + k) % mine.length];
            final name = leaves.firstWhere((n) => n.id == iid).name;
            return SharedInterest(iid, name, rare: k == 0 && p.isEven);
          }(),
      ];
      cards.add(
        FeedCard(
          userId: id,
          ageRange: person.ageRange,
          goal: goal,
          score: 92 - p * 7,
          explanation: _explain(shared),
          shared: shared,
          otherInterests: person.other,
          photoVerified: person.verified,
          ageVerified: person.verified,
          about: person.about,
          prompts: person.prompts,
          habits: person.habits,
          diet: person.diet,
        ),
      );
      if (cards.length >= limit) break;
    }
    return cards;
  }

  @override
  Future<InterestResult> expressInterest(String userId, String goal, {String? interestId}) async {
    _needUser();
    await _pause();
    _seen.add(userId);
    _likes++;
    // В демо каждый второй интерес взаимный — чтобы увидеть экран совпадения.
    final matched = _likes.isOdd;
    return InterestResult(matched, matched ? 'match-$userId' : '');
  }

  @override
  Future<void> skip(String userId, String goal) async {
    _needUser();
    _seen.add(userId);
  }
}

class _Node {
  const _Node(this.id, this.parent, this.name, this.synonyms);
  final String id;
  final String parent;
  final String name;
  final List<String> synonyms;
}

String _norm(String s) => s.toLowerCase().replaceAll('ё', 'е').trim();

/// «3 общих интереса: бонсай, эндуро, садоводство» — как на сервере.
String _explain(List<SharedInterest> shared) {
  if (shared.isEmpty) return 'Похожие цели и привычки';
  final n = shared.length;
  final word = _plural(n, 'общий интерес', 'общих интереса', 'общих интересов');
  final names = shared.take(3).map((s) => s.name.toLowerCase()).join(', ');
  return '$n $word: $names${n > 3 ? ' и другие' : ''}';
}

String _plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

class _Person {
  const _Person(
    this.ageRange,
    this.shared,
    this.other,
    this.about, {
    this.verified = false,
    this.prompts = const [],
    this.habits = const {},
    this.diet = '',
  });
  final String ageRange;
  final int shared;
  final int other;
  final String about;
  final bool verified;
  final List<Prompt> prompts;
  final Map<String, String> habits;
  final String diet;
}

const _people = [
  _Person(
    '25–29',
    3,
    6,
    'Люблю выбираться за город на выходных и пробовать новое.',
    verified: true,
    prompts: [Prompt('Идеальная суббота', 'Утром поход, вечером настолки с друзьями')],
    habits: {'smoking': 'no', 'sport': 'regular'},
  ),
  _Person(
    '30–34',
    2,
    9,
    'Работаю инженером, по вечерам учусь чему-нибудь руками.',
    prompts: [Prompt('Чему могу научить', 'Паять и чинить старую технику')],
    habits: {'smoking': 'no', 'chronotype': 'owl'},
    diet: 'vegetarian',
  ),
  _Person(
    '25–29',
    4,
    3,
    'Ищу компанию для путешествий и долгих разговоров.',
    verified: true,
    habits: {'alcohol': 'sometimes'},
  ),
  _Person(
    '35–39',
    1,
    12,
    'Спокойный, домашний, но легко соглашаюсь на авантюры.',
    prompts: [Prompt('Лучший совет, который я получал', 'Не откладывать на понедельник')],
  ),
  _Person(
    '20–24',
    2,
    5,
    'Студентка, рисую и хожу на йогу. Хочу найти своих людей.',
    verified: true,
    habits: {'smoking': 'no', 'sport': 'sometimes'},
  ),
  _Person(
    '40–44',
    3,
    7,
    'Двое детей, собака и дача. Ищу друзей семьями.',
    habits: {'has_kids': 'yes', 'pets': 'has'},
  ),
];
