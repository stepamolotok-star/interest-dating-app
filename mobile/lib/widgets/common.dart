import 'package:material_ui/material_ui.dart';

import '../api/api.dart';
import '../theme.dart';

/// Показывает ошибку внизу экрана.
void showError(BuildContext context, Object error) {
  final text = error is ApiException ? _capitalize(error.message) : 'Что-то пошло не так, попробуйте ещё раз';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
}

void showInfo(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
}

String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Каркас шага регистрации: заголовок, подзаголовок, содержимое и кнопка внизу.
class StepScaffold extends StatelessWidget {
  const StepScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
    required this.button,
    this.secondary,
    this.step,
    this.onBack,
    this.scrollable = true,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget button;

  /// Второе действие под кнопкой, например «Пропустить».
  final Widget? secondary;

  /// Номер шага из 5 (телефон, о себе, цели, интересы, анкета); null — без индикатора.
  final int? step;
  final VoidCallback? onBack;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: scrollable ? MainAxisSize.min : MainAxisSize.max,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        if (subtitle != null) ...[
          const SizedBox(height: 10),
          Text(subtitle!, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppColors.muted)),
        ],
        const SizedBox(height: 24),
        if (scrollable) child else Expanded(child: child),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        leading: onBack == null ? null : IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack),
        automaticallyImplyLeading: false,
        title: step == null ? null : StepDots(step: step!, total: 5),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: scrollable
                  ? SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 20), child: content)
                  : Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 0), child: content),
            ),
            Padding(padding: EdgeInsets.fromLTRB(20, 8, 20, secondary == null ? 16 : 4), child: button),
            if (secondary != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: secondary),
          ],
        ),
      ),
    );
  }
}

class StepDots extends StatelessWidget {
  const StepDots({super.key, required this.step, required this.total});

  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= total; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == step ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i <= step ? AppColors.accent : AppColors.line,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}

/// Кнопка с индикатором загрузки: пока идёт [onPressed], повторно не нажимается.
class BusyButton extends StatefulWidget {
  const BusyButton({super.key, required this.label, required this.onPressed, this.color});

  final String label;

  /// null — кнопка неактивна.
  final Future<void> Function()? onPressed;
  final Color? color;

  @override
  State<BusyButton> createState() => _BusyButtonState();
}

class _BusyButtonState extends State<BusyButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      await widget.onPressed!();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: widget.color == null ? null : FilledButton.styleFrom(backgroundColor: widget.color),
      onPressed: widget.onPressed == null || _busy ? null : _run,
      child: _busy
          ? SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.onAccent),
            )
          : Text(widget.label),
    );
  }
}

/// Небольшая плашка: цель, бейдж, привычка.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this._color, this._background, this.icon});

  final String text;
  final Color? _color;
  final Color? _background;
  final IconData? icon;

  /// По умолчанию — приглушённый текст на белой (в тёмной теме — тёмной) плашке.
  Color get color => _color ?? AppColors.muted;
  Color get background => _background ?? AppColors.surface;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: background == AppColors.surface ? Border.all(color: AppColors.line) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Плашка «демо-режим», чтобы никто не принял фальшивых людей за настоящих.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.warnBg, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(Icons.science_outlined, size: 18, color: AppColors.warnFg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: AppColors.warnFg, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
