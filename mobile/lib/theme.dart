import 'package:material_ui/material_ui.dart';

/// Цвета из макетов.
abstract final class AppColors {
  static const bg = Color(0xFFF6F4F0);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF1B1A1F);
  static const muted = Color(0xFF5E5B66);
  static const line = Color(0xFFE4E0D9);
  static const accent = Color(0xFF0E7A6A);
  static const accentTint = Color(0xFFDDF1EC);
  static const error = Color(0xFFB42318);
}

/// Цель знакомства: как её показывать.
class GoalInfo {
  const GoalInfo(this.id, this.label, this.hint, this.color, this.tint);

  final String id;
  final String label;
  final String hint;
  final Color color;
  final Color tint;

  bool get needsVerification => id == 'casual';
}

const goals = <GoalInfo>[
  GoalInfo(
    'family',
    'Серьёзные отношения и семья',
    'Для тех, кто думает о браке и детях',
    Color(0xFFBE123C),
    Color(0xFFFCE4EA),
  ),
  GoalInfo(
    'romance',
    'Романтика',
    'Свидания и симпатия без долгих планов',
    Color(0xFFC2410C),
    Color(0xFFFDEBDD),
  ),
  GoalInfo(
    'casual',
    'Без обязательств',
    'Только 18+: нужно подтвердить возраст',
    Color(0xFF7E22CE),
    Color(0xFFF2E6FB),
  ),
  GoalInfo('friendship', 'Дружба', 'Новые друзья рядом', AppColors.accent, AppColors.accentTint),
  GoalInfo(
    'hobby',
    'Партнёр по хобби',
    'С кем заниматься любимым делом',
    Color(0xFF1D4ED8),
    Color(0xFFE0E8FB),
  ),
  GoalInfo('talk', 'Собеседник', 'Поговорить о том, что важно', Color(0xFF0369A1), Color(0xFFE0F0FA)),
  GoalInfo('travel', 'Попутчик', 'Вместе в поездку или поход', Color(0xFF4D7C0F), Color(0xFFEAF3DC)),
  GoalInfo(
    'likeminded',
    'Единомышленники',
    'Люди с теми же взглядами и делами',
    Color(0xFF7C5E10),
    Color(0xFFF5EED9),
  ),
];

GoalInfo goalInfo(String id) => goals.firstWhere((g) => g.id == id, orElse: () => goals[3]);

/// Короткие подписи целей для чипов.
const goalShort = {
  'family': 'Семья',
  'romance': 'Романтика',
  'casual': 'Без обязательств',
  'friendship': 'Дружба',
  'hobby': 'Хобби',
  'talk': 'Общение',
  'travel': 'Попутчик',
  'likeminded': 'Единомышленники',
};

const levels = {
  'want_to_learn': 'Хочу научиться',
  'curious': 'Интересуюсь',
  'doing': 'Занимаюсь',
  'serious': 'Увлечён всерьёз',
  'pro': 'Профи',
};

ThemeData buildTheme() {
  const text = TextTheme(
    headlineMedium: TextStyle(
      fontFamily: 'Unbounded',
      fontWeight: FontWeight.w700,
      fontSize: 26,
      height: 1.15,
      color: AppColors.ink,
    ),
    headlineSmall: TextStyle(
      fontFamily: 'Unbounded',
      fontWeight: FontWeight.w700,
      fontSize: 20,
      height: 1.2,
      color: AppColors.ink,
    ),
    titleMedium: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: AppColors.ink),
    bodyLarge: TextStyle(fontSize: 16, height: 1.4, color: AppColors.ink),
    bodyMedium: TextStyle(fontSize: 14, height: 1.4, color: AppColors.ink),
    bodySmall: TextStyle(fontSize: 13, height: 1.35, color: AppColors.muted),
    labelLarge: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
  );
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    primary: AppColors.accent,
    surface: AppColors.bg,
    error: AppColors.error,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    fontFamily: 'Manrope',
    textTheme: text,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: 'Manrope',
        fontWeight: FontWeight.w800,
        fontSize: 18,
        color: AppColors.ink,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.line,
        minimumSize: const Size.fromHeight(54),
        shape: shape,
        textStyle: const TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.ink,
        minimumSize: const Size.fromHeight(54),
        side: const BorderSide(color: AppColors.line, width: 1.5),
        shape: shape,
        textStyle: const TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accent,
        textStyle: const TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
      labelStyle: const TextStyle(color: AppColors.muted),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.accentTint,
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w600, fontSize: 12),
      ),
    ),
    dividerColor: AppColors.line,
  );
}

/// Подписи привычек на карточке: ключ → значение → текст.
const habitLabels = {
  'smoking': {'no': 'Не курю', 'sometimes': 'Курю иногда', 'yes': 'Курю'},
  'alcohol': {'no': 'Не пью', 'sometimes': 'Пью редко', 'yes': 'Пью'},
  'sport': {'no': 'Без спорта', 'sometimes': 'Спорт иногда', 'regular': 'Спорт регулярно'},
  'chronotype': {'lark': 'Жаворонок', 'owl': 'Сова'},
  'pets': {'has': 'Есть питомец', 'wants': 'Хочу питомца', 'no': 'Без питомцев'},
  'has_kids': {'yes': 'Есть дети', 'no': 'Детей нет'},
  'wants_kids': {'yes': 'Хочу детей', 'no': 'Не хочу детей', 'unsure': 'Про детей — пока не знаю'},
};

const dietLabels = {
  'any': 'Ем всё',
  'vegetarian': 'Вегетарианство',
  'vegan': 'Веганство',
  'pescatarian': 'Пескетарианство',
  'halal': 'Халяль',
  'kosher': 'Кошер',
  'healthy': 'ПП',
  'keto': 'Кето',
  'raw': 'Сыроедение',
  'fasting': 'Соблюдаю посты',
};

/// Названия привычек в анкете.
const habitTitles = {
  'smoking': 'Курение',
  'alcohol': 'Алкоголь',
  'sport': 'Спорт',
  'chronotype': 'Режим дня',
  'pets': 'Питомцы',
  'has_kids': 'Дети',
  'wants_kids': 'Хочу детей',
};

const bodyTypes = {
  'slim': 'Худощавое',
  'athletic': 'Спортивное',
  'average': 'Среднее',
  'dense': 'Плотное',
  'large': 'Крупное',
};

const religions = {
  'orthodox': 'Православие',
  'christian': 'Другое христианство',
  'islam': 'Ислам',
  'buddhism': 'Буддизм',
  'judaism': 'Иудаизм',
  'other': 'Другое',
  'none': 'Не придерживаюсь религии',
};

/// Вопросы для анкеты: на них проще ответить, чем написать «о себе» с нуля.
const promptQuestions = [
  'Идеальные выходные — это…',
  'Чему могу научить',
  'Хочу научиться',
  'Лучший совет, который мне давали',
  'Меня легко рассмешить, если…',
  'Самое необычное моё увлечение',
  'Ищу человека, который…',
  'Место, где мне хорошо',
];

/// Кто видит поле анкеты.
const fieldVisibilityLabels = {
  'anonymous': 'Все в ленте',
  'after_match': 'После взаимного интереса',
  'matching_only': 'Только для подбора',
  'hidden': 'Никто',
};

const zodiacLabels = {
  'aries': 'Овен',
  'taurus': 'Телец',
  'gemini': 'Близнецы',
  'cancer': 'Рак',
  'leo': 'Лев',
  'virgo': 'Дева',
  'libra': 'Весы',
  'scorpio': 'Скорпион',
  'sagittarius': 'Стрелец',
  'capricorn': 'Козерог',
  'aquarius': 'Водолей',
  'pisces': 'Рыбы',
};
