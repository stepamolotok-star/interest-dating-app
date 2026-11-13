import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../cities.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// «О себе»: имя, дата рождения, пол, город и два отдельных согласия (152-ФЗ).
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  final _name = TextEditingController();
  final _birth = TextEditingController();
  City? _cityPicked;
  String? _gender;
  bool _terms = false;
  bool _personalData = false;

  /// Человек уже нажимал «Дальше» — показываем, что не так, у каждого поля.
  bool _tried = false;
  final _nameKey = GlobalKey(), _birthKey = GlobalKey(), _genderKey = GlobalKey();
  final _cityKey = GlobalKey(), _consentKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _birth]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _birth]) {
      c.dispose();
    }
    super.dispose();
  }

  DateTime? get _birthDate {
    final m = RegExp(r'^(\d{2})\.(\d{2})\.(\d{4})$').firstMatch(_birth.text);
    if (m == null) return null;
    final d = int.parse(m[1]!), mo = int.parse(m[2]!), y = int.parse(m[3]!);
    final date = DateTime(y, mo, d);
    // DateTime молча переносит 31.02 на март — такие даты отбрасываем.
    if (date.day != d || date.month != mo || y < 1900) return null;
    return date;
  }

  int? get _age {
    final b = _birthDate;
    if (b == null) return null;
    final now = DateTime.now();
    var age = now.year - b.year;
    if (now.month < b.month || (now.month == b.month && now.day < b.day)) age--;
    return age;
  }

  String? get _nameError => _tried && _name.text.trim().length < 2 ? 'Напишите имя — хотя бы 2 буквы' : null;

  String? get _birthError {
    if (_birth.text.length < 10) return _tried ? 'Введите дату полностью: ДД.ММ.ГГГГ' : null;
    final age = _age;
    if (age == null) return 'Проверьте дату';
    if (age < 18) return 'Приложение только для тех, кому есть 18';
    if (age > 100) return 'Проверьте год';
    return null;
  }

  bool get _ready =>
      _name.text.trim().length >= 2 &&
      _age != null &&
      _birthError == null &&
      _gender != null &&
      _cityPicked != null &&
      _terms &&
      _personalData;

  /// «Дальше» всегда нажимается: если что-то не так, подсвечиваем поля красным
  /// и прокручиваем к первому из них.
  Future<void> _next() async {
    if (!_ready) {
      setState(() => _tried = true);
      final first = [
        if (_name.text.trim().length < 2) _nameKey,
        if (_age == null || _birthError != null) _birthKey,
        if (_gender == null) _genderKey,
        if (_cityPicked == null) _cityKey,
        if (!_terms || !_personalData) _consentKey,
      ].firstOrNull;
      final ctx = first?.currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.2);
      }
      return;
    }
    await AppScope.read(context).register(
      Registration(
        name: _name.text.trim(),
        birthDate: _birthDate!,
        gender: _gender!,
        city: _cityPicked!.name,
        cityId: _cityPicked!.id,
        terms: _terms,
        personalData: _personalData,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      step: 2,
      title: 'О себе',
      subtitle: 'Имя и возраст будут видны в анкете. Саму дату рождения не увидит никто.',
      button: BusyButton(label: 'Дальше', onPressed: _next),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyedSubtree(
            key: _nameKey,
            child: TextField(
              key: const Key('name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              maxLength: 40,
              decoration: InputDecoration(labelText: 'Имя', counterText: '', errorText: _nameError),
            ),
          ),
          const SizedBox(height: 12),
          KeyedSubtree(
            key: _birthKey,
            child: TextField(
              key: const Key('birth'),
              controller: _birth,
              keyboardType: TextInputType.number,
              inputFormatters: [_DateFormatter()],
              decoration: InputDecoration(
                labelText: 'Дата рождения',
                hintText: 'ДД.ММ.ГГГГ',
                errorText: _birthError,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(key: _genderKey, 'Пол', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final (id, label) in const [('female', 'Женщина'), ('male', 'Мужчина')]) ...[
                Expanded(
                  child: _Choice(
                    label: label,
                    selected: _gender == id,
                    error: _tried && _gender == null,
                    onTap: () => setState(() => _gender = id),
                  ),
                ),
                if (id == 'female') const SizedBox(width: 10),
              ],
            ],
          ),
          if (_tried && _gender == null) const _ErrorLine('Выберите пол'),
          const SizedBox(height: 16),
          InkWell(
            key: const Key('city'),
            borderRadius: BorderRadius.circular(14),
            onTap: () async {
              final picked = await pickCity(context);
              if (picked != null) setState(() => _cityPicked = picked);
            },
            child: InputDecorator(
              key: _cityKey,
              isEmpty: _cityPicked == null,
              decoration: InputDecoration(
                labelText: 'Город',
                suffixIcon: const Icon(Icons.search),
                errorText: _tried && _cityPicked == null ? 'Выберите город из списка' : null,
              ),
              child: _cityPicked == null
                  ? null
                  : Text(_cityPicked!.label, style: Theme.of(context).textTheme.bodyLarge),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 6),
            child: Text(
              'Живёте в посёлке или селе — выберите ближайший город.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(key: _consentKey),
          _Consent(
            key: const Key('terms'),
            error: _tried && !_terms,
            value: _terms,
            onChanged: (v) => setState(() => _terms = v),
            text: 'Принимаю пользовательское соглашение',
          ),
          _Consent(
            key: const Key('personal_data'),
            error: _tried && !_personalData,
            value: _personalData,
            onChanged: (v) => setState(() => _personalData = v),
            text: 'Даю согласие на обработку персональных данных',
          ),
          if (_tried && (!_terms || !_personalData))
            const Padding(
              padding: EdgeInsets.only(left: 48),
              child: _ErrorLine('Без этих двух согласий зарегистрироваться нельзя'),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 48, top: 2),
            child: Text(
              'Это два разных документа — так требует закон. Данные хранятся в России.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Красная строка под полем, которое нужно заполнить.
class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, top: 6),
    child: Text(text, style: const TextStyle(color: AppColors.error, fontSize: 13)),
  );
}

class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.selected, required this.onTap, this.error = false});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.accentTint : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: error
              ? AppColors.error
              : selected
              ? AppColors.accent
              : AppColors.line,
          width: selected || error ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 15),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: selected ? AppColors.accent : AppColors.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Consent extends StatelessWidget {
  const _Consent({
    super.key,
    required this.value,
    required this.onChanged,
    required this.text,
    this.error = false,
  });

  final bool error;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String text;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Checkbox(value: value, isError: error, onChanged: (v) => onChanged(v ?? false)),
            const SizedBox(width: 4),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

/// Превращает цифры в «ДД.ММ.ГГГГ».
class _DateFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    var d = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (d.length > 8) d = d.substring(0, 8);
    final b = StringBuffer();
    for (var i = 0; i < d.length; i++) {
      if (i == 2 || i == 4) b.write('.');
      b.write(d[i]);
    }
    final text = b.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Выбор города из справочника. Одноимённые города различаются регионом.
Future<City?> pickCity(BuildContext context) => showModalBottomSheet<City>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  backgroundColor: AppColors.bg,
  builder: (_) => const _CitySheet(),
);

class _CitySheet extends StatefulWidget {
  const _CitySheet();

  @override
  State<_CitySheet> createState() => _CitySheetState();
}

class _CitySheetState extends State<_CitySheet> {
  final _q = TextEditingController();
  Cities? _cities;

  @override
  void initState() {
    super.initState();
    _q.addListener(() => setState(() {}));
    Cities.load().then((c) {
      if (mounted) setState(() => _cities = c);
    });
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final results = _cities?.search(_q.text) ?? const <City>[];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextField(
                key: const Key('city-search'),
                controller: _q,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  hintText: 'Начните вводить город',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            Expanded(
              child: _q.text.trim().isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Все города России. Если вашего посёлка нет — выберите ближайший город.',
                        style: t.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    )
                  : results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Такого города нет в списке. Проверьте название или выберите ближайший город.',
                        style: t.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, i) {
                        final c = results[i];
                        return ListTile(
                          key: Key('city-${c.id}'),
                          title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: c.region.isEmpty ? null : Text(c.region, style: t.bodySmall),
                          onTap: () => Navigator.of(context).pop(c),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
