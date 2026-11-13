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

class SvoiApp extends StatelessWidget {
  const SvoiApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'Свои',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
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
