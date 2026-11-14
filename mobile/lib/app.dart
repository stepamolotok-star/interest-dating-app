import 'package:material_ui/material_ui.dart';

import 'screens/about_screen.dart';
import 'screens/code_screen.dart';
import 'screens/goals_screen.dart';
import 'screens/home_screen.dart';
import 'screens/interests_screen.dart';
import 'screens/profile_step_screen.dart';
import 'screens/phone_screen.dart';
import 'state.dart';
import 'theme.dart';

/// Даёт экранам доступ к [AppState] и перестраивает их при изменениях.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Без подписки на изменения — для обработчиков нажатий.
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

class SvoiApp extends StatefulWidget {
  const SvoiApp({super.key, required this.state});

  final AppState state;

  @override
  State<SvoiApp> createState() => _SvoiAppState();
}

/// Следит за темой: выбор в профиле или, если «как в системе», настройка телефона.
/// Цвета [AppColors] не константы, поэтому при смене темы перестраиваем всё дерево.
class _SvoiAppState extends State<SvoiApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(_applyTheme);
    AppColors.dark = _wantDark;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.removeListener(_applyTheme);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _applyTheme();

  bool get _wantDark => switch (widget.state.themeMode) {
    ThemeMode.dark => true,
    ThemeMode.light => false,
    ThemeMode.system => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark,
  };

  void _applyTheme() {
    final dark = _wantDark;
    if (dark == AppColors.dark || !mounted) return;
    AppColors.dark = dark;
    void rebuild(Element e) {
      e.markNeedsBuild();
      e.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: MaterialApp(
        title: 'Свои',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        // Тему перестраиваем целиком — без плавного перехода, иначе часть цветов поменяется раньше.
        themeAnimationDuration: Duration.zero,
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final stage = AppScope.of(context).stage;
    final Widget screen = switch (stage) {
      Stage.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
      Stage.phone => const PhoneScreen(),
      Stage.code => const CodeScreen(),
      Stage.about => const AboutScreen(),
      Stage.goals => const GoalsScreen(onboarding: true),
      Stage.interests => const InterestsScreen(onboarding: true),
      Stage.profile => const ProfileStepScreen(),
      Stage.home => const HomeScreen(),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: KeyedSubtree(key: ValueKey(stage), child: screen),
    );
  }
}
