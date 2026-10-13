import 'package:et_core/et_core.dart';
import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.dart';
import 'widgets.dart';

/// Справка, открытая с того экрана, о котором спрашивают.
///
/// Лист, а не отдельная страница: человек не уходит с экрана, где застрял, — он приоткрывает
/// подсказку поверх него и закрывает обратно. Уводить его в другой раздел посреди заполнения
/// формы значит потерять то, что он уже набрал.
Future<void> showHelpArticle(BuildContext context, HelpArticle article) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _HelpSheet(article: article),
  );
}

/// Значок «?» в шапке экрана.
///
/// Если статьи с таким именем нет, кнопки просто не будет: молчащий вопросительный знак хуже,
/// чем его отсутствие — по нему жмут и решают, что приложение сломалось.
class EtHelpButton extends StatelessWidget {
  const EtHelpButton({super.key, required this.articleId});

  final String articleId;

  @override
  Widget build(BuildContext context) {
    final article = helpArticle(articleId);
    if (article == null) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Как это работает',
      icon: const Icon(Icons.help_outline),
      onPressed: () => showHelpArticle(context, article),
    );
  }
}

class _HelpSheet extends StatelessWidget {
  const _HelpSheet({required this.article});

  final HelpArticle article;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, controller) => Container(
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(EtShape.radiusCard)),
        ),
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(EtShape.gutter, 12, EtShape.gutter, 28),
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(color: c.line, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 18),
            const EtEyebrow('Помощь'),
            const SizedBox(height: 6),
            Text(article.title, style: context.texts.headlineSmall),
            const SizedBox(height: 12),

            // Ответ одной фразой — первым и крупно. Кто дальше не читает, уже знает, что делать.
            EtNotice(text: article.lead, icon: Icons.lightbulb_outline),

            if (article.where.isNotEmpty) ...[
              const SizedBox(height: EtShape.gap),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.explore_outlined, size: 18, color: c.inkDim),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      article.where,
                      style: context.texts.bodyMedium?.copyWith(color: c.inkDim),
                    ),
                  ),
                ],
              ),
            ],

            if (article.steps.isNotEmpty) ...[
              const SizedBox(height: EtShape.gap),
              EtCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < article.steps.length; i++) ...[
                      if (i > 0) const SizedBox(height: 12),
                      _Step(number: i + 1, text: article.steps[i]),
                    ],
                  ],
                ),
              ),
            ],

            if (article.notes.isNotEmpty) ...[
              const SizedBox(height: EtShape.gap),
              Text('Обо что спотыкаются', style: context.texts.titleSmall),
              const SizedBox(height: 8),
              for (final note in article.notes) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline, size: 18, color: c.rust),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          note,
                          style: context.texts.bodySmall?.copyWith(color: c.ink, height: 1.45),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],

            const SizedBox(height: EtShape.gap),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Понятно'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.greenTint, shape: BoxShape.circle),
          child: Text(
            '$number',
            style: context.texts.bodySmall?.copyWith(color: c.green, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(text, style: context.texts.bodyMedium?.copyWith(height: 1.45)),
          ),
        ),
      ],
    );
  }
}
