import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../cities.dart';
import '../models.dart';
import 'api.dart';

/// Демо-режим: работает без сервера. Данные хранятся на телефоне и переживают перезапуск.
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
  final _oauthStates = <String>{};
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
  ContactsStatus _contacts = const ContactsStatus();
  ProfileFields _profile = ProfileFields();
  bool _specialConsent = false;
  final _prefs = <String, Map<String, dynamic>>{};
  final _fieldVisibility = <String, String>{
    'about': 'anonymous',
    'prompts': 'anonymous',
    'habits': 'anonymous',
    'diet': 'anonymous',
    'languages': 'anonymous',
    'height': 'matching_only',
    'weight': 'matching_only',
    'body_type': 'matching_only',
    'religion': 'hidden',
    'photos': 'anonymous',
  };

  @override
  bool get isDemo => true;

  static const _storeKey = 'demo_state_v1';

  /// Поднимает сохранённое состояние демо-режима.
  @override
  Future<void> init() async {
    final raw = (await SharedPreferences.getInstance()).getString(_storeKey);
    if (raw == null) return;
    try {
      _restore(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Формат поменялся между версиями — начинаем с чистого листа.
    }
  }

  void _save() {
    final state = jsonEncode(_dump());
    // Не получилось записать — не страшно: демо продолжит работать в памяти.
    SharedPreferences.getInstance().then((p) => p.setString(_storeKey, state)).catchError((_) => false);
  }

  Map<String, dynamic> _dump() => {
    'registered': _registered,
    if (_reg != null)
      'reg': {
        'name': _reg!.name,
        'birth_date': _reg!.birthDate.toIso8601String(),
        'gender': _reg!.gender,
        'city': _reg!.city,
        'city_id': _reg!.cityId,
      },
    'goals': [for (final g in _goals) g.toJson()],
    'interests': [
      for (final i in _interests) {...i.toJson(), 'name': i.name},
    ],
    'seen': _seen.toList(),
    'likes': _likes,
    'matches': [for (final m in _matches) m.toJson()],
    'messages': {
      for (final e in _messages.entries) e.key: [for (final m in e.value) m.toJson()],
    },
    'next_message_id': _nextMessageId,
    'visibility': {
      'mode': _visibility.mode,
      'visible_until': _visibility.visibleUntil?.toUtc().toIso8601String(),
      'radius_m': _visibility.radiusM,
      'verified_only': _visibility.verifiedOnly,
    },
    'zones': [for (final z in _zones) z.toJson()],
    'next_zone_id': _nextZoneId,
    'contacts': {'count': _contacts.count, 'hide': _contacts.hide},
    'profile': _profile.toJson(),
    'special_consent': _specialConsent,
    'field_visibility': _fieldVisibility,
    'prefs': _prefs,
  };

  void _restore(Map<String, dynamic> j) {
    List<Map<String, dynamic>> list(String k) => ((j[k] as List?) ?? const []).cast<Map<String, dynamic>>();
    _registered = j['registered'] as bool? ?? false;
    final reg = j['reg'] as Map<String, dynamic>?;
    if (reg != null) {
      _reg = Registration(
        name: reg['name'] as String,
        birthDate: DateTime.parse(reg['birth_date'] as String),
        gender: reg['gender'] as String,
        city: reg['city'] as String,
        cityId: reg['city_id'] as String? ?? '',
        terms: true,
        personalData: true,
      );
    }
    _goals = list('goals').map(GoalSetting.fromJson).toList();
    _interests = list('interests').map(MyInterest.fromJson).toList();
    _seen.addAll(((j['seen'] as List?) ?? const []).cast<String>());
    _likes = j['likes'] as int? ?? 0;
    _matches.addAll(list('matches').map(Match.fromJson));
    for (final e in ((j['messages'] as Map?) ?? const {}).entries) {
      _messages[e.key as String] = (e.value as List)
          .cast<Map<String, dynamic>>()
          .map(Message.fromJson)
          .toList();
    }
    _nextMessageId = j['next_message_id'] as int? ?? 1;
    _visibility = NearbyVisibility.fromJson((j['visibility'] as Map<String, dynamic>?) ?? const {});
    _zones.addAll(list('zones').map(Zone.fromJson));
    _nextZoneId = j['next_zone_id'] as int? ?? 1;
    final c = (j['contacts'] as Map<String, dynamic>?) ?? const {};
    _contacts = ContactsStatus(count: c['count'] as int? ?? 0, hide: c['hide'] as bool? ?? false);
    _profile = ProfileFields.fromJson((j['profile'] as Map<String, dynamic>?) ?? const {});
    _specialConsent = j['special_consent'] as bool? ?? false;
    _fieldVisibility.addAll(((j['field_visibility'] as Map?) ?? const {}).cast<String, String>());
    for (final e in ((j['prefs'] as Map?) ?? const {}).entries) {
      _prefs[e.key as String] = Map<String, dynamic>.of(e.value as Map<String, dynamic>);
    }
  }

  Future<List<_Node>> _catalog() async {
    if (_nodes != null) return _nodes!;
    // Не loadString: файлы больше 50 КБ он разбирает в отдельном isolate.
    final raw =
        catalogJson ?? utf8.decode((await rootBundle.load('assets/data/catalog.json')).buffer.asUint8List());
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final rawNodes = (data['nodes'] as List).cast<Map<String, dynamic>>();
    final byId = {for (final n in rawNodes) n['id'] as String: n};
    String kindOf(Map<String, dynamic> n) {
      for (Map<String, dynamic>? cur = n; cur != null; cur = byId[cur['parent']]) {
        final k = cur['kind'] as String? ?? '';
        if (k.isNotEmpty) return k;
      }
      return '';
    }

    _nodes = [
      for (final n in rawNodes)
        _Node(
          n['id'] as String,
          n['parent'] as String? ?? '',
          n['name'] as String,
          ((n['synonyms'] as List?) ?? const []).cast<String>(),
          kindOf(n),
        ),
    ];
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
    return InterestNode(
      id: n.id,
      name: n.name,
      hasChildren: all.any((x) => x.parent == n.id),
      path: path,
      kind: n.kind,
    );
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
    if ((await Cities.load()).byId(r.cityId) == null) {
      throw const ApiException(400, 'выберите город из списка', field: 'city');
    }
    _reg = r;
    _registered = true;
    _save();
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
    final city = (await Cities.load()).byId(r.cityId);
    return Me(userId: _myId, name: r.name, city: city?.name ?? r.city, region: city?.region ?? '', age: age);
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
      throw const ApiException(403, 'для этой цели подтвердите, что вам есть 18 лет');
    }
    _goals = List.of(goals);
    _save();
  }

  @override
  Future<List<MyInterest>> interests() async {
    _needUser();
    final all = await _catalog();
    String kind(String id) => all.where((n) => n.id == id).firstOrNull?.kind ?? '';
    return [
      for (final i in _interests)
        MyInterest(
          id: i.id,
          name: i.name,
          level: i.level,
          seekingPartner: i.seekingPartner,
          kind: kind(i.id),
        ),
    ];
  }

  @override
  Future<void> setInterests(List<MyInterest> items) async {
    _needUser();
    await _pause();
    final all = await _catalog();
    _interests = [
      for (final i in items)
        if (all.firstWhere((n) => n.id == i.id) case final n)
          MyInterest(
            id: i.id,
            name: n.name,
            level: n.kind == 'fan' ? 'curious' : i.level,
            seekingPartner: i.seekingPartner,
            kind: n.kind,
          ),
    ];
    _save();
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
      // Из фильтров демо учитывает пол, «только проверенных» и минимум общих интересов.
      final prefs = GoalPrefs.fromJson(_prefs[goal] ?? const {});
      if (prefs.genders.isNotEmpty && !prefs.genders.contains(person.female ? 'female' : 'male')) continue;
      if (prefs.verifiedOnly && !person.verified) continue;
      if (count < prefs.minShared) continue;
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
          age: person.age,
          name: person.name,
          // Кто прячет свои фото до взаимности, не видит и чужие — как на сервере.
          photosHidden:
              goal == 'casual' || person.photosAfterMatch || _fieldVisibility['photos'] == 'after_match',
          goal: goal,
          score: 92 - p * 7,
          explanation: _explain(shared),
          shared: shared,
          otherInterests: person.other,
          others: [
            ...person.extraInterests,
            for (var k = 0; leaves.isNotEmpty && k < person.other - person.extraInterests.length; k++)
              leaves[(p * 37 + k * 11) % leaves.length].name,
          ].take(person.other).toList(),
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
    if (!matched) {
      _save();
      return const InterestResult(false, '');
    }
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
    _save();
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
        _save();
      });
    }
    _save();
    return m;
  }

  @override
  Future<void> endMatch(String matchId) async {
    _needUser();
    _chat(matchId);
    _matches.removeWhere((m) => m.matchId == matchId);
    _messages.remove(matchId);
    _save();
  }

  @override
  Future<void> block(String userId) async {
    _needUser();
    for (final m in _matches.where((m) => m.other.userId == userId).toList()) {
      _matches.remove(m);
      _messages.remove(m.matchId);
    }
    _seen.add(userId);
    _save();
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
    _save();
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
    _save();
    return visibility();
  }

  @override
  Future<void> disappear() async {
    _needUser();
    _visibility = NearbyVisibility(radiusM: _visibility.radiusM);
    _position = null;
    _save();
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
    _save();
    return z;
  }

  @override
  Future<void> deleteZone(String id) async {
    _needUser();
    _zones.removeWhere((z) => z.id == id);
    _save();
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
            age: c.age,
            name: c.name,
            // Фото рядом с расстоянием до взаимности не показываем — как на сервере.
            photosHidden: true,
            goal: c.goal,
            score: c.score,
            explanation: c.explanation,
            shared: c.shared,
            otherInterests: c.otherInterests,
            others: c.others,
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

  @override
  Future<ContactsStatus> contactsStatus() async {
    _needUser();
    return _contacts;
  }

  @override
  Future<ContactsStatus> uploadContacts(List<String> hashes) async {
    _needUser();
    await _pause();
    if (hashes.length > 5000) throw const ApiException(400, 'не больше 5000 номеров');
    _contacts = ContactsStatus(count: hashes.toSet().length, hide: true);
    _save();
    return _contacts;
  }

  @override
  Future<void> clearContacts() async {
    _needUser();
    _contacts = const ContactsStatus();
    _save();
  }

  @override
  Future<ProfileFields> profile() async {
    _needUser();
    return _profile.copy();
  }

  @override
  Future<void> updateProfile(ProfileFields fields, {bool grantSpecial = false}) async {
    _needUser();
    await _pause();
    if (fields.about.length > 500) throw const ApiException(400, 'не длиннее 500 символов', field: 'about');
    if (fields.religion.isNotEmpty && !grantSpecial && !_specialConsent) {
      throw const ApiException(
        403,
        'чтобы указать религию, нужно отдельное согласие на обработку таких данных',
      );
    }
    if (grantSpecial) _specialConsent = true;
    if (fields.religion.isEmpty) _specialConsent = false;
    _profile = fields.copy();
    _save();
  }

  @override
  Future<Map<String, String>> fieldVisibility() async {
    _needUser();
    return Map.of(_fieldVisibility);
  }

  @override
  Future<void> setFieldVisibility(Map<String, String> changes) async {
    _needUser();
    _fieldVisibility.addAll(changes);
    _save();
  }

  @override
  Future<GoalPrefs> prefs(String goal) async {
    _needUser();
    return GoalPrefs.fromJson(_prefs[goal] ?? const {});
  }

  @override
  Future<void> setPrefs(String goal, GoalPrefs prefs) async {
    _needUser();
    await _pause();
    const physical = {'family', 'romance', 'casual'};
    if (!physical.contains(goal) && (!prefs.height.isEmpty || !prefs.weight.isEmpty)) {
      throw const ApiException(400, 'рост и вес можно задавать только в романтических целях');
    }
    _prefs[goal] = prefs.toJson();
    _save();
  }

  @override
  Future<List<AuthProvider>> authProviders() async => const [
    AuthProvider('vk', 'VK ID'),
    AuthProvider('yandex', 'Яндекс ID'),
  ];

  @override
  Future<OAuthStart> oauthStart(String provider) async {
    final state = 'demo-${DateTime.now().microsecondsSinceEpoch}';
    _oauthStates.add(state);
    return OAuthStart(
      'https://demo.invalid/$provider/authorize?state=$state',
      state,
      'ru.svoi://oauth/$provider',
    );
  }

  @override
  Future<Session> oauthFinish(
    String provider, {
    required String state,
    required String code,
    String deviceId = '',
  }) async {
    await _pause();
    if (!_oauthStates.remove(state)) {
      throw const ApiException(400, 'вход занял слишком много времени — попробуйте ещё раз');
    }
    token = 'demo-token';
    return Session(token!, _registered);
  }
}

class _Node {
  const _Node(this.id, this.parent, this.name, this.synonyms, this.kind);
  final String id;
  final String parent;
  final String name;
  final List<String> synonyms;
  final String kind;
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
    this.photosAfterMatch = false,
  });

  /// Человек сам решил открывать фото только после взаимного интереса.
  final bool photosAfterMatch;
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
    photosAfterMatch: true,
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
