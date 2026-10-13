import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.dart';

/// Шапка туши: вид мяса словом, на своём цвете.
///
/// У лота редко есть фотография — хозяйство снимает животное уже по заказу, а не на витрину.
/// Пустое место под фото выглядит как «не загрузилось», поэтому его занимает типографика: то же,
/// что на сайте делают карточки-плитки «Говядина» и «Конина».
///
/// Цвета взяты у сайта дословно (.meat-tile): тёмный тёплый градиент для говядины, тёмный
/// зелёный для конины. Бледные тинты, которые стояли здесь раньше, выглядели как недогруженная
/// картинка; тёмная плитка со светлым словом читается как продукт. Поверх — та же диагональная
/// штриховка в 3 % белого, что даёт сайту фактуру вместо плоской заливки.
///
/// Полоса намеренно НЕВЫСОКАЯ: это метка, а не иллюстрация, и она не должна съедать экран, на
/// котором человек выбирает тушу. Если фотография есть — показывается она, а слово ложится
/// поверх затемнения.
class EtHero extends StatelessWidget {
  const EtHero({
    super.key,
    required this.label,
    this.meatType = 'cattle',
    this.imageUrl,
    this.height = 84,
    this.note,
    this.rounded = true,
  });

  /// «Говядина» / «Конина».
  final String label;

  /// cattle | horse — от него зависит цвет, как на сайте.
  final String meatType;

  final String? imageUrl;
  final double height;

  /// Короткая приписка справа: вес, возраст — одно слово.
  final String? note;

  /// Скруглять верхние углы. В карточке — да, во всю ширину экрана — нет: там скруглённые углы
  /// выглядят как оторвавшаяся карточка под шапкой.
  final bool rounded;

  /// .meat-tile--cattle / --horse с сайта.
  static const _tiles = {
    'cattle': (Color(0xFF2E2019), Color(0xFF6E3B22)),
    'horse': (Color(0xFF1B2620), Color(0xFF3F5238)),
  };

  @override
  Widget build(BuildContext context) {
    final tile = _tiles[meatType] ?? _tiles['cattle']!;
    final url = imageUrl;
    final hasPhoto = url != null && url.isNotEmpty;

    return ClipRRect(
      borderRadius: rounded
          ? const BorderRadius.vertical(top: Radius.circular(EtShape.radiusCard))
          : BorderRadius.zero,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [tile.$1, tile.$2],
                ),
              ),
            ),

            if (hasPhoto)
              Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => const SizedBox.shrink(),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : const SizedBox.shrink(),
              ),

            // Над фотографией — затемнение слева, чтобы слово читалось на любом снимке.
            if (hasPhoto)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xCC000000), Color(0x33000000)],
                  ),
                ),
              ),

            // Фактура: диагональная штриховка в 3 % белого — то же, чем сайт оживляет заливки.
            const Positioned.fill(child: CustomPaint(painter: _Hatch())),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: EtShape.gutter),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.titleLarge?.copyWith(
                        color: const Color(0xFFF6F1E7),
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  if (note != null)
                    Text(
                      note!,
                      style: context.texts.labelMedium?.copyWith(
                        color: const Color(0xB3F6F1E7),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Диагональные полоски в 3 % белого с шагом 11 px — линия в линию с CSS сайта
/// (`linear-gradient(135deg, rgba(255,255,255,.03) 0 1px, transparent 1px 11px)`).
class _Hatch extends CustomPainter {
  const _Hatch();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x08FFFFFF)
      ..strokeWidth = 1;
    const step = 11.0;
    for (var x = -size.height; x < size.width; x += step) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _Hatch oldDelegate) => false;
}

/// Панель внизу экрана с главным действием.
///
/// Без неё кнопка висит прямо над содержимым, и последняя карточка уезжает под неё — так было на
/// экране туши: «Разделка» пряталась за «Выбрать формат и заказать». Панель даёт кнопке свой фон,
/// линию сверху и безопасные отступы, а списку — понятную нижнюю границу.
class EtBottomBar extends StatelessWidget {
  const EtBottomBar({super.key, required this.child, this.caption});

  final Widget child;

  /// Строка над кнопкой: цена, срок, предупреждение — то, с чем человек нажимает.
  final Widget? caption;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        border: Border(top: BorderSide(color: c.line)),
        boxShadow: EtShape.soft(Theme.of(context).brightness == Brightness.dark),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(EtShape.gutter, 12, EtShape.gutter, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (caption != null) ...[
                caption!,
                const SizedBox(height: 10),
              ],
              child,
            ],
          ),
        ),
      ),
    );
  }
}
