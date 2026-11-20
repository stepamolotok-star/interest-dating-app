import 'package:flutter/services.dart' show rootBundle;

/// Пользовательские документы. Тексты — assets/legal/*.md, копия
/// backend/internal/legal/texts (сервер проверяет, что они не разошлись).
/// Данные оператора подставляются при сборке: --dart-define=LEGAL_OPERATOR=… и т. д.
enum LegalDoc {
  terms('terms', 'Пользовательское соглашение'),
  privacy('privacy', 'Политика обработки персональных данных'),
  personalData('personal-data', 'Согласие на обработку персональных данных'),
  specialCategory('special-category', 'Согласие на обработку сведений о религиозных убеждениях'),
  rules('rules', 'Правила сообщества'),
  recommendations('recommendations', 'Правила применения рекомендательных технологий');

  const LegalDoc(this.file, this.title);

  final String file;
  final String title;
}

/// Редакция документов — как legal.Updated на сервере.
const legalUpdated = '21 ноября 2026 г.';

/// Данные оператора; не заданы — в тексте видны метки «[…]».
const appName = String.fromEnvironment('APP_NAME', defaultValue: 'Свои');
const legalOperator = String.fromEnvironment('LEGAL_OPERATOR');
const legalOperatorId = String.fromEnvironment('LEGAL_OPERATOR_ID');
const supportEmail = String.fromEnvironment('LEGAL_EMAIL');

String fillLegal(String md) => md
    .replaceAll('{{APP}}', appName)
    .replaceAll('{{OPERATOR}}', legalOperator.isEmpty ? '[ФИО оператора]' : legalOperator)
    .replaceAll('{{OPERATOR_ID}}', legalOperatorId.isEmpty ? '[ИНН оператора]' : legalOperatorId)
    .replaceAll('{{EMAIL}}', supportEmail.isEmpty ? '[адрес электронной почты]' : supportEmail)
    .replaceAll('{{UPDATED}}', legalUpdated);

Future<String> loadLegal(LegalDoc d) async => fillLegal(await rootBundle.loadString('assets/legal/${d.file}.md'));

/// Кусок документа: заголовок, абзац или пункт списка.
sealed class LegalBlock {
  const LegalBlock();
}

class LegalHeading extends LegalBlock {
  const LegalHeading(this.text, this.level);
  final String text;
  final int level;
}

class LegalParagraph extends LegalBlock {
  const LegalParagraph(this.text);
  final String text;
}

class LegalItem extends LegalBlock {
  const LegalItem(this.text, {this.number, this.sub = const []});
  final String text;

  /// Номер для нумерованного списка; null — маркер.
  final int? number;

  /// Вложенный список.
  final List<String> sub;
}

/// Разбирает ту же простую разметку, что сервер: «#», «##», абзацы, «-», «1.», вложенный «-», **жирный**.
List<LegalBlock> parseLegal(String md) {
  final out = <LegalBlock>[];
  final para = <String>[];
  void flush() {
    if (para.isNotEmpty) {
      out.add(LegalParagraph(para.join(' ')));
      para.clear();
    }
  }

  final ordered = RegExp(r'^(\d+)\. (.*)$');
  for (final raw in md.split('\n')) {
    final line = raw.trimRight();
    final trimmed = line.trimLeft();
    final indented = line.length - trimmed.length >= 2;
    if (trimmed.isEmpty) {
      flush();
    } else if (line.startsWith('# ')) {
      flush();
      out.add(LegalHeading(line.substring(2), 1));
    } else if (line.startsWith('## ')) {
      flush();
      out.add(LegalHeading(line.substring(3), 2));
    } else if (indented && trimmed.startsWith('- ') && out.isNotEmpty && out.last is LegalItem) {
      final last = out.removeLast() as LegalItem;
      out.add(LegalItem(last.text, number: last.number, sub: [...last.sub, trimmed.substring(2)]));
    } else if (line.startsWith('- ')) {
      flush();
      out.add(LegalItem(line.substring(2)));
    } else if (ordered.firstMatch(line) case final m?) {
      flush();
      out.add(LegalItem(m.group(2)!, number: int.parse(m.group(1)!)));
    } else {
      para.add(trimmed);
    }
  }
  flush();
  return out;
}
