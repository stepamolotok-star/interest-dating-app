import 'package:material_ui/material_ui.dart';

import '../legal.dart';
import '../theme.dart';

/// Документ: соглашение, политика, согласия, правила.
class LegalScreen extends StatelessWidget {
  const LegalScreen(this.doc, {super.key});

  final LegalDoc doc;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(doc.title, maxLines: 2, style: const TextStyle(fontSize: 17))),
      body: FutureBuilder<String>(
        future: loadLegal(doc),
        builder: (context, snap) {
          final md = snap.data;
          if (md == null) return const Center(child: CircularProgressIndicator());
          // Заголовок документа уже в шапке.
          final blocks = parseLegal(md).skipWhile((b) => b is LegalHeading && b.level == 1).toList();
          return SelectionArea(
            child: ListView.builder(
              key: Key('legal-${doc.file}'),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              itemCount: blocks.length,
              itemBuilder: (context, i) => _Block(blocks[i]),
            ),
          );
        },
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block(this.b);

  final LegalBlock b;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final body = t.bodyLarge?.copyWith(height: 1.45);
    return switch (b) {
      LegalHeading(:final text) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 6),
        child: Text(text, style: t.titleLarge),
      ),
      LegalParagraph(:final text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text.rich(_rich(text), style: body),
      ),
      LegalItem(:final text, :final number, :final sub) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 26,
              child: Text(number == null ? '•' : '$number.', style: body?.copyWith(color: AppColors.accent)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(_rich(text), style: body),
                  for (final s in sub)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 18,
                            child: Text('–', style: body?.copyWith(color: AppColors.muted)),
                          ),
                          Expanded(child: Text.rich(_rich(s), style: body)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    };
  }
}

/// **жирный** → жирный шрифт.
TextSpan _rich(String s) {
  final parts = s.split('**');
  return TextSpan(
    children: [
      for (var i = 0; i < parts.length; i++)
        TextSpan(
          text: parts[i],
          style: i.isOdd && i < parts.length - 1 ? const TextStyle(fontWeight: FontWeight.w700) : null,
        ),
    ],
  );
}

/// Открыть документ.
Future<void> openLegal(BuildContext context, LegalDoc d) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LegalScreen(d)));
