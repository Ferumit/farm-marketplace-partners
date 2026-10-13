import 'package:et_core/et_core.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// «Помощь» — место, куда идут, когда застряли.
///
/// Подсказки на экранах говорят по одной вещи и в свой момент; сюда приходят с вопросом, который
/// возник позже и не на том экране. Поэтому главное здесь не список, а поиск: человек набирает
/// «счёт» или «куда платят», а не листает оглавление.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _writeToSupport() async {
    final text = Uri.encodeComponent('Здравствуйте! Я фермер, пользуюсь ET Partners. Вопрос: ');
    final uri = Uri.parse('https://wa.me/$supportWhatsApp?text=$text');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final found = searchHelp(_query.text);

    return Scaffold(
      appBar: AppBar(title: const Text('Помощь')),
      body: ListView(
        padding: const EdgeInsets.all(EtShape.gutter),
        children: [
          TextField(
            controller: _query,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Что ищете? Например: счёт, лот, доставка',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(_query.clear),
                    ),
            ),
          ),
          const SizedBox(height: EtShape.gap),

          if (found.isEmpty)
            EtEmpty(
              title: 'Ничего не нашлось',
              text: 'Попробуйте другое слово — например «счёт», «лот» или «доставка».'
                  '${supportWhatsApp.isEmpty ? '' : ' Или напишите в поддержку, там ответят словами.'}',
              icon: Icons.search_off,
            )
          else
            for (var i = 0; i < found.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              EtReveal(index: i, child: _articleCard(found[i])),
            ],

          if (supportWhatsApp.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Не нашли ответ?', style: context.texts.titleSmall),
            const SizedBox(height: 8),
            Text(
              'Сделайте снимок экрана, на котором застряли, и пришлите его — по снимку видно сразу, '
              'где заминка.',
              style: context.texts.bodySmall?.copyWith(color: c.inkDim),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _writeToSupport,
              icon: const Icon(Icons.chat_outlined, size: 18),
              label: const Text('Написать в поддержку'),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _articleCard(HelpArticle article) {
    final c = context.et;
    return EtCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: EtShape.cardRadius,
        onTap: () => showHelpArticle(context, article),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(article.title, style: context.texts.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      article.lead,
                      style: context.texts.bodySmall?.copyWith(color: c.inkDim, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, size: 20, color: c.inkFaint),
            ],
          ),
        ),
      ),
    );
  }
}
