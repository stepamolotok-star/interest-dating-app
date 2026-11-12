/// Модели ответов API. Поля называются так же, как в JSON бэкенда.
library;

class Challenge {
  const Challenge({required this.method, required this.codeLength, required this.resendAfter});

  factory Challenge.fromJson(Map<String, dynamic> j) => Challenge(
    method: j['method'] as String? ?? 'call',
    codeLength: j['code_length'] as int? ?? 4,
    resendAfter: j['resend_after'] as int? ?? 60,
  );

  /// call — звонок-сброс, sms — сообщение.
  final String method;
  final int codeLength;
  final int resendAfter;
}

class Session {
  const Session(this.token, this.registered);
  final String token;
  final bool registered;
}

class Me {
  const Me({
    required this.userId,
    required this.name,
    required this.city,
    required this.age,
    this.photoVerified = false,
    this.ageVerified = false,
  });

  factory Me.fromJson(Map<String, dynamic> j) => Me(
    userId: j['user_id'] as String,
    name: j['name'] as String? ?? '',
    city: j['city'] as String? ?? '',
    age: j['age'] as int? ?? 0,
    photoVerified: j['photo_verified'] as bool? ?? false,
    ageVerified: j['age_verified'] as bool? ?? false,
  );

  final String userId;
  final String name;
  final String city;
  final int age;
  final bool photoVerified;
  final bool ageVerified;
}

class Registration {
  const Registration({
    required this.name,
    required this.birthDate,
    required this.gender,
    required this.city,
    required this.terms,
    required this.personalData,
  });

  final String name;
  final DateTime birthDate;
  final String gender; // male | female
  final String city;
  final bool terms;
  final bool personalData;

  Map<String, dynamic> toJson() => {
    'name': name,
    'birth_date':
        '${birthDate.year.toString().padLeft(4, '0')}-'
        '${birthDate.month.toString().padLeft(2, '0')}-'
        '${birthDate.day.toString().padLeft(2, '0')}',
    'gender': gender,
    'city': city,
    'consents': {'terms': terms, 'personal_data': personalData},
  };
}

/// Узел каталога интересов.
class InterestNode {
  const InterestNode({required this.id, required this.name, this.hasChildren = false, this.path = const []});

  factory InterestNode.fromJson(Map<String, dynamic> j) => InterestNode(
    id: j['id'] as String,
    name: j['name'] as String,
    hasChildren: j['has_children'] as bool? ?? false,
    path: (j['path'] as List?)?.cast<String>() ?? const [],
  );

  final String id;
  final String name;
  final bool hasChildren;

  /// Цепочка названий от категории до узла — только в результатах поиска.
  final List<String> path;
}

/// Интерес в профиле.
class MyInterest {
  MyInterest({required this.id, this.name = '', this.level = 'doing', this.seekingPartner = false});

  factory MyInterest.fromJson(Map<String, dynamic> j) => MyInterest(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    level: j['level'] as String? ?? 'doing',
    seekingPartner: j['seeking_partner'] as bool? ?? false,
  );

  final String id;
  String name;
  String level;
  bool seekingPartner;

  Map<String, dynamic> toJson() => {'id': id, 'level': level, 'seeking_partner': seekingPartner};
}

class GoalSetting {
  const GoalSetting(this.goal, {this.active = true, this.nearbyVisible = false});

  factory GoalSetting.fromJson(Map<String, dynamic> j) => GoalSetting(
    j['goal'] as String,
    active: j['active'] as bool? ?? true,
    nearbyVisible: j['nearby_visible'] as bool? ?? false,
  );

  final String goal;
  final bool active;
  final bool nearbyVisible;

  Map<String, dynamic> toJson() => {'goal': goal, 'active': active, 'nearby_visible': nearbyVisible};
}

class SharedInterest {
  const SharedInterest(this.id, this.name, {this.rare = false});

  factory SharedInterest.fromJson(Map<String, dynamic> j) =>
      SharedInterest(j['id'] as String, j['name'] as String, rare: j['rare'] as bool? ?? false);

  final String id;
  final String name;
  final bool rare;
}

class Prompt {
  const Prompt(this.question, this.answer);

  factory Prompt.fromJson(Map<String, dynamic> j) =>
      Prompt(j['question'] as String? ?? '', j['answer'] as String? ?? '');

  final String question;
  final String answer;
}

/// Анонимная карточка ленты: без имени и фото до взаимного интереса.
class FeedCard {
  const FeedCard({
    required this.userId,
    required this.ageRange,
    required this.goal,
    required this.score,
    required this.explanation,
    required this.shared,
    this.otherInterests = 0,
    this.photoVerified = false,
    this.ageVerified = false,
    this.about = '',
    this.prompts = const [],
    this.habits = const {},
    this.diet = '',
    this.zodiac = '',
    this.distance = '',
  });

  factory FeedCard.fromJson(Map<String, dynamic> j) => FeedCard(
    userId: j['user_id'] as String,
    ageRange: j['age_range'] as String? ?? '',
    goal: j['goal'] as String? ?? '',
    score: j['score'] as int? ?? 0,
    explanation: j['explanation'] as String? ?? '',
    shared: ((j['shared_interests'] as List?) ?? const [])
        .map((e) => SharedInterest.fromJson(e as Map<String, dynamic>))
        .toList(),
    otherInterests: j['other_interests_count'] as int? ?? 0,
    photoVerified: j['photo_verified'] as bool? ?? false,
    ageVerified: j['age_verified'] as bool? ?? false,
    about: j['about'] as String? ?? '',
    prompts: ((j['prompts'] as List?) ?? const [])
        .map((e) => Prompt.fromJson(e as Map<String, dynamic>))
        .toList(),
    habits: ((j['habits'] as Map?) ?? const {}).cast<String, String>(),
    diet: j['diet'] as String? ?? '',
    zodiac: j['zodiac'] as String? ?? '',
    distance: j['distance'] as String? ?? '',
  );

  final String userId;
  final String ageRange;
  final String goal;
  final int score;
  final String explanation;
  final List<SharedInterest> shared;
  final int otherInterests;
  final bool photoVerified;
  final bool ageVerified;
  final String about;
  final List<Prompt> prompts;
  final Map<String, String> habits;
  final String diet;
  final String zodiac;
  final String distance;
}

class InterestResult {
  const InterestResult(this.matched, this.matchId);

  factory InterestResult.fromJson(Map<String, dynamic> j) =>
      InterestResult(j['matched'] as bool? ?? false, j['match_id'] as String? ?? '');

  final bool matched;
  final String matchId;
}

/// Собеседник после взаимного интереса: имя, возраст, о себе, интересы.
class Person {
  const Person({
    required this.userId,
    required this.name,
    required this.age,
    this.about = '',
    this.prompts = const [],
    this.interests = const [],
  });

  factory Person.fromJson(Map<String, dynamic> j) => Person(
    userId: j['user_id'] as String,
    name: j['name'] as String? ?? '',
    age: j['age'] as int? ?? 0,
    about: j['about'] as String? ?? '',
    prompts: ((j['prompts'] as List?) ?? const [])
        .map((e) => Prompt.fromJson(e as Map<String, dynamic>))
        .toList(),
    interests: ((j['interests'] as List?) ?? const []).cast<String>(),
  );

  final String userId;
  final String name;
  final int age;
  final String about;
  final List<Prompt> prompts;
  final List<String> interests;
}

class Message {
  const Message({
    required this.id,
    required this.sender,
    required this.kind,
    required this.body,
    required this.createdAt,
  });

  factory Message.fromJson(Map<String, dynamic> j) => Message(
    id: j['id'] as int,
    sender: j['sender'] as String? ?? '',
    kind: j['kind'] as String? ?? 'text',
    body: j['body'] as String? ?? '',
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
  );

  final int id;
  final String sender;

  /// text — обычное сообщение, system — служебное («Вы совпали…»).
  final String kind;
  final String body;
  final DateTime createdAt;

  bool get isSystem => kind == 'system';
}

/// Взаимный интерес: с кем, по какой цели и последнее сообщение.
class Match {
  const Match({
    required this.matchId,
    required this.goal,
    required this.createdAt,
    required this.other,
    this.lastMessage,
  });

  factory Match.fromJson(Map<String, dynamic> j) => Match(
    matchId: j['match_id'] as String,
    goal: j['goal'] as String? ?? '',
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
    other: Person.fromJson(j['other'] as Map<String, dynamic>),
    lastMessage: j['last_message'] == null
        ? null
        : Message.fromJson(j['last_message'] as Map<String, dynamic>),
  );

  final String matchId;
  final String goal;
  final DateTime createdAt;
  final Person other;
  final Message? lastMessage;

  /// Переписка ещё не началась (служебные сообщения не в счёт).
  bool get isNew => lastMessage == null || lastMessage!.isSystem;
}

/// Настройки видимости в «Рядом».
class NearbyVisibility {
  const NearbyVisibility({
    this.mode = 'off',
    this.visibleUntil,
    this.radiusM = 1000,
    this.verifiedOnly = false,
    this.hideFromContacts = false,
    this.active = false,
  });

  factory NearbyVisibility.fromJson(Map<String, dynamic> j) => NearbyVisibility(
    mode: j['mode'] as String? ?? 'off',
    visibleUntil: j['visible_until'] == null ? null : DateTime.parse(j['visible_until'] as String).toLocal(),
    radiusM: j['radius_m'] as int? ?? 1000,
    verifiedOnly: j['verified_only'] as bool? ?? false,
    hideFromContacts: j['hide_from_contacts'] as bool? ?? false,
    active: j['active'] as bool? ?? false,
  );

  /// off — невидим; foreground — пока открыто приложение; timed — на несколько часов;
  /// background — и в фоне (появится вместе с фоновой геолокацией).
  final String mode;
  final DateTime? visibleUntil;
  final int radiusM;

  /// Показываться только тем, кто подтвердил возраст или фото.
  final bool verifiedOnly;

  /// Не показываться людям из своей телефонной книги.
  final bool hideFromContacts;

  /// Видим прямо сейчас (для timed — пока не истекло время).
  final bool active;
}

/// Личная зона: здесь человека не видно в «Рядом».
class Zone {
  const Zone({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.radiusM,
  });

  factory Zone.fromJson(Map<String, dynamic> j) => Zone(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    lat: (j['lat'] as num).toDouble(),
    lon: (j['lon'] as num).toDouble(),
    radiusM: j['radius_m'] as int? ?? 500,
  );

  final String id;
  final String name;
  final double lat;
  final double lon;
  final int radiusM;
}

/// Ответ на отправку геопозиции: видно ли сейчас человека и почему нет.
class LocationStatus {
  const LocationStatus(this.visible, [this.reason = '']);

  factory LocationStatus.fromJson(Map<String, dynamic> j) =>
      LocationStatus(j['visible'] as bool? ?? false, j['reason'] as String? ?? '');

  final bool visible;

  /// visibility_off | private_zone
  final String reason;
}

/// «Скрыть меня от контактов»: включено ли и сколько номеров учтено.
class ContactsStatus {
  const ContactsStatus({this.count = 0, this.hide = false});

  factory ContactsStatus.fromJson(Map<String, dynamic> j) =>
      ContactsStatus(count: j['count'] as int? ?? 0, hide: j['hide'] as bool? ?? false);

  final int count;
  final bool hide;
}

/// Анкета: то, что человек рассказывает о себе. Кто что видит — в [FieldVisibility].
class ProfileFields {
  ProfileFields({
    this.about = '',
    List<Prompt>? prompts,
    this.heightCm,
    this.weightKg,
    this.bodyType = '',
    Map<String, String>? habits,
    this.diet = '',
    this.religion = '',
    this.religionForMatching = false,
    this.showZodiac = false,
    List<Map<String, dynamic>>? languages,
  }) : prompts = prompts ?? [],
       habits = habits ?? {},
       languages = languages ?? [];

  factory ProfileFields.fromJson(Map<String, dynamic> j) => ProfileFields(
    about: j['about'] as String? ?? '',
    prompts: ((j['prompts'] as List?) ?? const [])
        .map((e) => Prompt.fromJson(e as Map<String, dynamic>))
        .toList(),
    heightCm: j['height_cm'] as int?,
    weightKg: j['weight_kg'] as int?,
    bodyType: j['body_type'] as String? ?? '',
    habits: ((j['habits'] as Map?) ?? const {}).cast<String, String>(),
    diet: j['diet'] as String? ?? '',
    religion: j['religion'] as String? ?? '',
    religionForMatching: j['religion_for_matching'] as bool? ?? false,
    showZodiac: j['show_zodiac'] as bool? ?? false,
    languages: ((j['languages'] as List?) ?? const []).cast<Map<String, dynamic>>(),
  );

  String about;
  List<Prompt> prompts;
  int? heightCm;
  int? weightKg;
  String bodyType;
  Map<String, String> habits;
  String diet;
  String religion;
  bool religionForMatching;
  bool showZodiac;

  /// Языки пока не редактируются в приложении, но сохраняются как есть.
  List<Map<String, dynamic>> languages;

  Map<String, dynamic> toJson() => {
    'about': about,
    'prompts': [
      for (final p in prompts) {'question': p.question, 'answer': p.answer},
    ],
    'height_cm': heightCm,
    'weight_kg': weightKg,
    'body_type': bodyType,
    'habits': habits,
    'diet': diet,
    'religion': religion,
    'religion_for_matching': religionForMatching,
    'show_zodiac': showZodiac,
    'languages': languages,
  };

  ProfileFields copy() => ProfileFields.fromJson(toJson());
}
