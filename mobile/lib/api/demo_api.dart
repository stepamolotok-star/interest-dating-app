import 'dart:convert';
import 'dart:math' as math;

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
  final _matches = <Match>[];
  final _messages = <String, List<Message>>{};
  final _cards = <String, FeedCard>{};
  int _nextMessageId = 1;

  /// Задержка ответа собеседника в демо.
  static const replyDelay = Duration(seconds: 2);
  static const _myId = 'demo-me';

  NearbyVisibility _visibility = const NearbyVisibility();
  final _zones = <Zone>[];
  ({double lat, double lon})? _position;
  int _nextZoneId = 1;

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
    return Me(userId: _myId, name: r.name, city: r.city, age: age);
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
        _cards[id] = FeedCard(
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
    if (!matched) return const InterestResult(false, '');
    final p = int.parse(userId.split('-').last);
    final person = _people[p];
    final card = _cards[userId];
    final matchId = 'match-$userId';
    _matches.insert(
      0,
      Match(
        matchId: matchId,
        goal: goal,
        createdAt: DateTime.now(),
        other: Person(
          userId: userId,
          name: person.name,
          age: person.age,
          about: person.about,
          prompts: person.prompts,
          interests: [...?card?.shared.map((s) => s.name), ...person.extraInterests],
        ),
      ),
    );
    _messages[matchId] = [];
    return InterestResult(true, matchId);
  }

  @override
  Future<List<Match>> matches() async {
    _needUser();
    await _pause();
    final out = [
      for (final m in _matches)
        Match(
          matchId: m.matchId,
          goal: m.goal,
          createdAt: m.createdAt,
          other: m.other,
          lastMessage: _messages[m.matchId]!.lastOrNull,
        ),
    ];
    DateTime last(Match m) => m.lastMessage?.createdAt ?? m.createdAt;
    out.sort((a, b) => last(b).compareTo(last(a)));
    return out;
  }

  List<Message> _chat(String matchId) {
    final list = _messages[matchId];
    if (list == null) throw const ApiException(404, 'переписка не найдена или закрыта');
    return list;
  }

  @override
  Future<List<Message>> messages(String matchId, {int? before}) async {
    _needUser();
    final list = _chat(matchId);
    return list.reversed.where((m) => before == null || m.id < before).take(50).toList();
  }

  @override
  Future<Message> send(String matchId, String body) async {
    _needUser();
    final list = _chat(matchId);
    final text = body.trim();
    if (text.isEmpty) throw const ApiException(400, 'пустое сообщение');
    if (list.isEmpty && hasContacts(text)) {
      throw const ApiException(
        422,
        'в первом сообщении нельзя оставлять ссылки и контакты — так часто действуют мошенники. '
        'Познакомьтесь сначала здесь',
      );
    }
    final m = Message(
      id: _nextMessageId++,
      sender: _myId,
      kind: 'text',
      body: text,
      createdAt: DateTime.now(),
    );
    list.add(m);
    // Собеседник отвечает на первое сообщение — чтобы в демо было с кем поговорить.
    if (list.where((x) => x.sender == _myId).length == 1) {
      final match = _matches.firstWhere((x) => x.matchId == matchId);
      final person = _people[int.parse(match.other.userId.split('-').last)];
      final topic = match.other.interests.isEmpty ? 'это' : match.other.interests.first.toLowerCase();
      Future<void>.delayed(replyDelay, () {
        if (!_messages.containsKey(matchId)) return;
        list.add(
          Message(
            id: _nextMessageId++,
            sender: match.other.userId,
            kind: 'text',
            body:
                'Привет! ${person.female ? 'Рада' : 'Рад'}, что совпали. Про $topic могу говорить часами. '
                'А ты как к этому пришёл(ла)?',
            createdAt: DateTime.now(),
          ),
        );
      });
    }
    return m;
  }

  @override
  Future<void> endMatch(String matchId) async {
    _needUser();
    _chat(matchId);
    _matches.removeWhere((m) => m.matchId == matchId);
    _messages.remove(matchId);
  }

  @override
  Future<void> block(String userId) async {
    _needUser();
    for (final m in _matches.where((m) => m.other.userId == userId).toList()) {
      _matches.remove(m);
      _messages.remove(m.matchId);
    }
    _seen.add(userId);
  }

  @override
  Future<bool> report(String userId, String reason, {String comment = ''}) async {
    _needUser();
    await _pause();
    return const {'threat', 'harassment', 'stalking', 'minor'}.contains(reason);
  }

  @override
  Future<void> skip(String userId, String goal) async {
    _needUser();
    _seen.add(userId);
  }

  bool get _visibleNow =>
      _visibility.mode == 'foreground' ||
      _visibility.mode == 'background' ||
      (_visibility.mode == 'timed' && (_visibility.visibleUntil?.isAfter(DateTime.now()) ?? false));

  @override
  Future<NearbyVisibility> visibility() async {
    _needUser();
    final v = _visibility;
    return NearbyVisibility(
      mode: v.mode,
      visibleUntil: v.visibleUntil,
      radiusM: v.radiusM,
      verifiedOnly: v.verifiedOnly,
      hideFromContacts: v.hideFromContacts,
      active: _visibleNow,
    );
  }

  @override
  Future<NearbyVisibility> setVisibility({
    required String mode,
    int hours = 0,
    int radiusM = 1000,
    bool verifiedOnly = false,
    bool hideFromContacts = false,
  }) async {
    _needUser();
    await _pause();
    if (mode == 'timed' && (hours < 1 || hours > 12)) throw const ApiException(400, 'от 1 до 12 часов');
    _visibility = NearbyVisibility(
      mode: mode,
      visibleUntil: mode == 'timed' ? DateTime.now().add(Duration(hours: hours)) : null,
      radiusM: radiusM,
      verifiedOnly: verifiedOnly,
      hideFromContacts: hideFromContacts,
    );
    if (mode == 'off') _position = null;
    return visibility();
  }

  @override
  Future<void> disappear() async {
    _needUser();
    _visibility = NearbyVisibility(radiusM: _visibility.radiusM);
    _position = null;
  }

  @override
  Future<List<Zone>> zones() async {
    _needUser();
    return List.of(_zones);
  }

  @override
  Future<Zone> addZone(String name, double lat, double lon, int radiusM) async {
    _needUser();
    await _pause();
    if (name.trim().isEmpty || name.length > 30) {
      throw const ApiException(400, 'название от 1 до 30 символов');
    }
    if (_zones.length >= 10) throw const ApiException(400, 'не больше 10 личных зон');
    final z = Zone(id: 'zone-${_nextZoneId++}', name: name.trim(), lat: lat, lon: lon, radiusM: radiusM);
    _zones.add(z);
    return z;
  }

  @override
  Future<void> deleteZone(String id) async {
    _needUser();
    _zones.removeWhere((z) => z.id == id);
  }

  @override
  Future<LocationStatus> updateLocation(double lat, double lon, {bool mocked = false}) async {
    _needUser();
    if (mocked) {
      throw const ApiException(403, 'похоже на подмену геопозиции — режим «Рядом» недоступен в течение часа');
    }
    if (!_visibleNow) {
      _position = null;
      return const LocationStatus(false, 'visibility_off');
    }
    if (_zones.any((z) => distanceM(lat, lon, z.lat, z.lon) <= z.radiusM)) {
      _position = null;
      return const LocationStatus(false, 'private_zone');
    }
    _position = (lat: lat, lon: lon);
    return const LocationStatus(true);
  }

  @override
  Future<List<FeedCard>> radar(String goal) async {
    _needUser();
    await _pause();
    if (!_visibleNow) {
      throw const ApiException(
        403,
        'чтобы видеть людей рядом, включите свою видимость: видеть других может только тот, кто виден сам',
      );
    }
    if (_position == null) {
      throw const ApiException(409, 'нет свежей геопозиции — откройте приложение с включённой геолокацией');
    }
    const buckets = ['до 500 м', 'до 1 км', 'до 1 км', '1–3 км', '3–10 км', '1–3 км'];
    const bucketMax = [500, 1000, 1000, 3000, 10000, 3000];
    final cards = await feed(goal);
    return [
      for (final (i, c) in cards.indexed)
        if (bucketMax[i % buckets.length] <= math.max(_visibility.radiusM, 1000) || i == 0)
          FeedCard(
            userId: c.userId,
            ageRange: c.ageRange,
            goal: c.goal,
            score: c.score,
            explanation: c.explanation,
            shared: c.shared,
            otherInterests: c.otherInterests,
            photoVerified: c.photoVerified,
            ageVerified: c.ageVerified,
            about: c.about,
            prompts: c.prompts,
            habits: c.habits,
            diet: c.diet,
            // «Без обязательств» ближе «до 1 км» не показываем — как на сервере.
            distance: goal == 'casual' && i % buckets.length == 0 ? 'до 1 км' : buckets[i % buckets.length],
          ),
    ];
  }
}

class _Node {
  const _Node(this.id, this.parent, this.name, this.synonyms);
  final String id;
  final String parent;
  final String name;
  final List<String> synonyms;
}

/// Упрощённая проверка на ссылки и контакты — как на сервере (chat.HasContacts).
bool hasContacts(String text) => RegExp(
  r'(https?://|www\.|t\.me/|wa\.me/|vk\.com/|@[a-z0-9_]{4,}|\b[a-z0-9-]+\.(ru|com|me|org|net)\b|'
  r'телег|\btg\b|whatsapp|ватсап|вотсап|вацап|вайбер|viber|инстаграм|instagram|'
  r'\+?[78][\s(-]*\d{3}[\s)-]*\d{3}[\s-]*\d{2}[\s-]*\d{2})',
  caseSensitive: false,
).hasMatch(text);

/// Расстояние по поверхности Земли в метрах.
double distanceM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
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
    this.name,
    this.age,
    this.ageRange,
    this.shared,
    this.other,
    this.about, {
    this.female = false,
    this.verified = false,
    this.prompts = const [],
    this.habits = const {},
    this.diet = '',
    this.extraInterests = const [],
  });
  final String name;
  final int age;
  final String ageRange;
  final int shared;
  final int other;
  final String about;
  final bool female;
  final bool verified;
  final List<Prompt> prompts;
  final Map<String, String> habits;
  final String diet;
  final List<String> extraInterests;
}

const _people = [
  _Person(
    'Марина',
    27,
    '25–29',
    3,
    6,
    'Люблю выбираться за город на выходных и пробовать новое.',
    female: true,
    verified: true,
    prompts: [Prompt('Идеальная суббота', 'Утром поход, вечером настолки с друзьями')],
    habits: {'smoking': 'no', 'sport': 'regular'},
    extraInterests: ['Походы', 'Настольные игры'],
  ),
  _Person(
    'Денис',
    32,
    '30–34',
    2,
    9,
    'Работаю инженером, по вечерам учусь чему-нибудь руками.',
    prompts: [Prompt('Чему могу научить', 'Паять и чинить старую технику')],
    habits: {'smoking': 'no', 'chronotype': 'owl'},
    diet: 'vegetarian',
    extraInterests: ['Электроника', 'Велосипед'],
  ),
  _Person(
    'Ольга',
    26,
    '25–29',
    4,
    3,
    'Ищу компанию для путешествий и долгих разговоров.',
    female: true,
    verified: true,
    habits: {'alcohol': 'sometimes'},
    extraInterests: ['Путешествия'],
  ),
  _Person(
    'Сергей',
    37,
    '35–39',
    1,
    12,
    'Спокойный, домашний, но легко соглашаюсь на авантюры.',
    prompts: [Prompt('Лучший совет, который я получал', 'Не откладывать на понедельник')],
    extraInterests: ['Рыбалка', 'Кулинария'],
  ),
  _Person(
    'Вика',
    21,
    '20–24',
    2,
    5,
    'Студентка, рисую и хожу на йогу. Хочу найти своих людей.',
    female: true,
    verified: true,
    habits: {'smoking': 'no', 'sport': 'sometimes'},
    extraInterests: ['Рисование'],
  ),
  _Person(
    'Андрей',
    42,
    '40–44',
    3,
    7,
    'Двое детей, собака и дача. Ищу друзей семьями.',
    habits: {'has_kids': 'yes', 'pets': 'has'},
    extraInterests: ['Дача', 'Собаки'],
  ),
];
