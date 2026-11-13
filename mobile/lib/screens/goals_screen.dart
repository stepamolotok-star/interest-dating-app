import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Выбор целей. Несколько целей можно держать одновременно.
class GoalsScreen extends StatefulWidget {
  const GoalsScreen({super.key, this.onboarding = false});

  /// true — шаг регистрации, false — правка из профиля.
  final bool onboarding;

  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  late final Set<String> _selected = AppScope.read(context).activeGoals.toSet();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final verified = state.me?.ageVerified ?? false;
    return StepScaffold(
      step: widget.onboarding ? 3 : null,
      onBack: widget.onboarding ? null : () => Navigator.of(context).pop(),
      title: 'Кого вы ищете?',
      subtitle: 'Можно выбрать несколько. Для каждой цели — своя лента и свои фильтры.',
      button: BusyButton(
        label: widget.onboarding ? 'Дальше' : 'Сохранить',
        onPressed: _selected.isEmpty
            ? null
            : () async {
                final ordered = [
                  for (final g in goals)
                    if (_selected.contains(g.id)) g.id,
                ];
                await AppScope.read(context).saveGoals(ordered);
                if (!widget.onboarding && context.mounted) Navigator.of(context).pop();
              },
      ),
      child: Column(
        children: [
          for (final g in goals)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _GoalTile(
                goal: g,
                selected: _selected.contains(g.id),
                locked: g.needsVerification && !verified,
                onTap: () {
                  if (g.needsVerification && !verified) {
                    showInfo(
                      context,
                      'Чтобы открыть эту цель, подтвердите, что вам есть 18 лет. Подтверждение скоро заработает.',
                    );
                    return;
                  }
                  setState(() => _selected.contains(g.id) ? _selected.remove(g.id) : _selected.add(g.id));
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _GoalTile extends StatelessWidget {
  const _GoalTile({required this.goal, required this.selected, required this.locked, required this.onTap});

  final GoalInfo goal;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? goal.tint : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? goal.color : AppColors.line, width: selected ? 1.5 : 1),
      ),
      child: InkWell(
        key: Key('goal-${goal.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: goal.color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      goal.label,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: locked ? AppColors.muted : AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(goal.hint, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              Icon(
                locked
                    ? Icons.lock_outline
                    : selected
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: locked
                    ? AppColors.muted
                    : selected
                    ? goal.color
                    : AppColors.line,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
