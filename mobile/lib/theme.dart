import 'package:material_ui/material_ui.dart';

/// Палитра одной темы.
class Palette {
  const Palette({
    required this.bg,
    required this.surface,
    required this.ink,
    required this.muted,
    required this.line,
    required this.accent,
    required this.accentTint,
    required this.onAccent,
    required this.fill,
    required this.onFill,
    required this.error,
    required this.warnBg,
    required this.warnFg,
  });

  final Color bg;
  final Color surface;
  final Color ink;
  final Color muted;
  final Color line;
  final Color accent;
  final Color accentTint;

  /// Текст на заливке акцентным цветом (выбранные цели и т. п.).
  final Color onAccent;

  /// Заливка главных кнопок и своих сообщений — тот же бирюзовый, что на значке приложения.
  final Color fill;
  final Color onFill;
  final Color error;

  /// Плашка «демо-режим» и другие предупреждения.
  final Color warnBg;
  final Color warnFg;
}

const lightPalette = Palette(
  bg: Color(0xFFF6F4F0),
  surface: Color(0xFFFFFFFF),
  ink: Color(0xFF1B1A1F),
  muted: Color(0xFF5E5B66),
  line: Color(0xFFE4E0D9),
  accent: Color(0xFF0E7A6A),
  accentTint: Color(0xFFDDF1EC),
  onAccent: Color(0xFFFFFFFF),
  fill: Color(0xFF0E7A6A),
  onFill: Color(0xFFFFFFFF),
  error: Color(0xFFB42318),
  warnBg: Color(0xFFFFF4D6),
  warnFg: Color(0xFF8A5A00),
);

/// Тёмная тема: тёплый почти чёрный фон, акцент светлее — чтобы читался на тёмном.
const darkPalette = Palette(
  bg: Color(0xFF131215),
  surface: Color(0xFF1E1D21),
  ink: Color(0xFFEDEBE7),
  muted: Color(0xFFA6A3AD),
  line: Color(0xFF34323A),
  accent: Color(0xFF4CC3AC),
  accentTint: Color(0xFF173A33),
  onAccent: Color(0xFF0B1F1B),
  fill: Color(0xFF0E7A6A),
  onFill: Color(0xFFFFFFFF),
  error: Color(0xFFF97066),
  warnBg: Color(0xFF33290F),
  warnFg: Color(0xFFF2C66D),
);

/// Цвета текущей темы. Меняются вместе с темой — поэтому не константы.
abstract final class AppColors {
  /// Сейчас включена тёмная тема.
  static bool dark = false;

  static Palette get p => dark ? darkPalette : lightPalette;

  static Color get bg => p.bg;
  static Color get surface => p.surface;
  static Color get ink => p.ink;
  static Color get muted => p.muted;
  static Color get line => p.line;
  static Color get accent => p.accent;
  static Color get accentTint => p.accentTint;
  static Color get onAccent => p.onAccent;
  static Color get fill => p.fill;
  static Color get onFill => p.onFill;
  static Color get error => p.error;
  static Color get warnBg => p.warnBg;
  static Color get warnFg => p.warnFg;
}

/// Цель знакомства: как её показывать.
class GoalInfo {
  const GoalInfo(this.id, this.label, this.hint, this._light, this._dark);

  final String id;
  final String label;
  final String hint;

  /// (цвет, подложка) для светлой и тёмной темы.
  final (Color, Color) _light;
  final (Color, Color) _dark;

  Color get color => (AppColors.dark ? _dark : _light).$1;

  /// Заливка кнопок цели («Интересно», «Написать»): насыщенный цвет с белым текстом
  /// в обеих темах — как зелёные кнопки, а не пастельный вариант для текста.
  Color get fill => _light.$1;
  Color get tint => (AppColors.dark ? _dark : _light).$2;

  bool get needsVerification => id == 'casual';
}

const goals = <GoalInfo>[
  GoalInfo(
    'family',
    'Серьёзные отношения и семья',
    'Для тех, кто думает о браке и детях',
    (Color(0xFFBE123C), Color(0xFFFCE4EA)),
    (Color(0xFFFB7185), Color(0xFF3D1620)),
  ),
  GoalInfo(
    'romance',
    'Романтика',
    'Свидания и симпатия без долгих планов',
    (Color(0xFFC2410C), Color(0xFFFDEBDD)),
    (Color(0xFFFB923C), Color(0xFF3A2414)),
  ),
  GoalInfo(
    'casual',
    'Без обязательств',
    'Только 18+: нужно подтвердить возраст',
    (Color(0xFF7E22CE), Color(0xFFF2E6FB)),
    (Color(0xFFC084FC), Color(0xFF2E1A40)),
  ),
  GoalInfo(
    'friendship',
    'Дружба',
    'Новые друзья рядом',
    (Color(0xFF0E7A6A), Color(0xFFDDF1EC)),
    (Color(0xFF4CC3AC), Color(0xFF173A33)),
  ),
  GoalInfo(
    'hobby',
    'Партнёр по хобби',
    'С кем заниматься любимым делом',
    (Color(0xFF1D4ED8), Color(0xFFE0E8FB)),
    (Color(0xFF7DA2FF), Color(0xFF1B2747)),
  ),
  GoalInfo(
    'talk',
    'Собеседник',
    'Поговорить о том, что важно',
    (Color(0xFF0369A1), Color(0xFFE0F0FA)),
    (Color(0xFF4FB3E8), Color(0xFF13293A)),
  ),
  GoalInfo(
    'travel',
    'Попутчик',
    'Вместе в поездку или поход',
    (Color(0xFF4D7C0F), Color(0xFFEAF3DC)),
    (Color(0xFF9BCB5A), Color(0xFF22301A)),
  ),
  GoalInfo(
    'likeminded',
    'Единомышленники',
    'Люди с теми же взглядами и делами',
    (Color(0xFF7C5E10), Color(0xFFF5EED9)),
    (Color(0xFFD6B45A), Color(0xFF33291A)),
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
  final text = TextTheme(
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
    labelLarge: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
  );
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: AppColors.dark ? Brightness.dark : Brightness.light,
    onPrimary: AppColors.onAccent,
    onSurface: AppColors.ink,
    primary: AppColors.accent,
    surface: AppColors.bg,
    error: AppColors.error,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  return ThemeData(
    brightness: AppColors.dark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    cardColor: AppColors.surface,
    dialogTheme: DialogThemeData(backgroundColor: AppColors.surface),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: AppColors.bg, modalBackgroundColor: AppColors.bg),
    popupMenuTheme: PopupMenuThemeData(color: AppColors.surface),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.dark ? const Color(0xFF2C2A30) : const Color(0xFF2B2A30),
      contentTextStyle: const TextStyle(fontFamily: 'Manrope', color: Color(0xFFF2F0EC)),
    ),
    scaffoldBackgroundColor: AppColors.bg,
    fontFamily: 'Manrope',
    textTheme: text,
    appBarTheme: AppBarTheme(
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
        backgroundColor: AppColors.fill,
        foregroundColor: AppColors.onFill,
        disabledBackgroundColor: AppColors.line,
        disabledForegroundColor: AppColors.muted,
        minimumSize: const Size.fromHeight(54),
        shape: shape,
        textStyle: const TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.ink,
        minimumSize: const Size.fromHeight(54),
        side: BorderSide(color: AppColors.line, width: 1.5),
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
        borderSide: BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AppColors.accent, width: 1.5),
      ),
      labelStyle: TextStyle(color: AppColors.muted),
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
