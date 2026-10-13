import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.dart';
import 'widgets.dart';

/// «Удалить аккаунт» - экран, которого требует Google Play, и который должен говорить правду.
///
/// Правда здесь важнее краткости: часть данных уходит навсегда, а часть остаётся - закрытые
/// заказы это запись о деньгах для обеих сторон, отзывы сложили рейтинг хозяйства. Человек имеет
/// право узнать это ДО нажатия, а не из письма в поддержку после.
///
/// Экран общий для обоих приложений: слова разные, устройство одно - список «что уйдёт», список
/// «что останется», ввод подтверждения и одна красная кнопка.
class EtDeleteAccountScreen extends StatefulWidget {
  const EtDeleteAccountScreen({
    super.key,
    required this.goes,
    required this.stays,
    required this.onDelete,
    this.note,
    this.confirmWord = 'УДАЛИТЬ',
  });

  /// Что будет стёрто, по-человечески: «профиль и номер», «корзина», «уведомления».
  final List<String> goes;

  /// Что останется и почему - иначе это выглядит как обман.
  final List<String> stays;

  /// Возвращает null, если аккаунт удалён, или текст отказа от сервера.
  final Future<String?> Function() onDelete;

  /// Строка сверху: чем этот аккаунт отличается (хозяйство, покупатель).
  final String? note;

  final String confirmWord;

  @override
  State<EtDeleteAccountScreen> createState() => _EtDeleteAccountScreenState();
}

class _EtDeleteAccountScreenState extends State<EtDeleteAccountScreen> {
  final _confirm = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _confirm.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  bool get _ready => _confirm.text.trim().toUpperCase() == widget.confirmWord;

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить аккаунт?'),
        content: const Text('Это нельзя отменить. Войти можно будет тем же номером, '
            'но это будет новый аккаунт с чистого листа.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Назад')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await widget.onDelete();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return Scaffold(
      appBar: AppBar(title: const Text('Удаление аккаунта')),
      body: ListView(
        padding: const EdgeInsets.all(EtShape.gutter),
        children: [
          if (widget.note != null) ...[
            EtNotice(text: widget.note!, icon: Icons.info_outline),
            const SizedBox(height: EtShape.gap),
          ],
          EtCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Что будет удалено', style: context.texts.titleSmall),
                const SizedBox(height: 10),
                for (final line in widget.goes) _line(Icons.remove_circle_outline, line, c.danger),
              ],
            ),
          ),
          const SizedBox(height: EtShape.gap),
          EtCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Что останется', style: context.texts.titleSmall),
                const SizedBox(height: 10),
                for (final line in widget.stays) _line(Icons.lock_outline, line, c.inkFaint),
              ],
            ),
          ),
          const SizedBox(height: EtShape.gap),
          EtCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Наберите ${widget.confirmWord}, чтобы подтвердить',
                  style: context.texts.bodyMedium,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _confirm,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(hintText: widget.confirmWord),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: EtShape.gap),
            EtNotice(text: _error!, icon: Icons.error_outline, tone: 'danger'),
          ],
          const SizedBox(height: EtShape.gap),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.danger),
            onPressed: _ready && !_busy ? _delete : null,
            child: Text(_busy ? 'Удаляем…' : 'Удалить аккаунт навсегда'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _line(IconData icon, String text, Color colour) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: colour),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: context.texts.bodySmall)),
          ],
        ),
      );
}
