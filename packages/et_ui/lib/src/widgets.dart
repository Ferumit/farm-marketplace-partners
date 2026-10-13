import 'package:flutter/material.dart';

import 'steppe.dart';
import 'theme.dart';
import 'tokens.dart';

/// A panel: the one container every screen builds from.
class EtCard extends StatelessWidget {
  const EtCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(EtShape.gutter),
    this.onTap,
    this.tinted = false,
  });

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  /// A faint green ground, for the one card on a screen that is asking for something.
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final card = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: tinted ? c.greenTint : c.surfaceRaised,
        borderRadius: EtShape.cardRadius,
        border: Border.all(color: tinted ? Colors.transparent : c.line),
        // Тень только у обычных карточек: подсвеченная (tinted) — это блок внутри потока, а не
        // отдельный предмет на странице.
        boxShadow: tinted ? null : EtShape.card(Theme.of(context).brightness == Brightness.dark),
      ),
      child: child,
    );
    if (onTap == null) return card;
    return InkWell(borderRadius: EtShape.cardRadius, onTap: onTap, child: card);
  }
}

/// Where an order stands, in one word. `tone` comes from et_core's statusTone, so the buyer's
/// screen and the farm's colour the same state the same way.
class EtStatusChip extends StatelessWidget {
  const EtStatusChip({super.key, required this.text, this.tone = 'neutral', this.icon});

  final String text;
  final String tone;

  /// Значок шага сделки: в списке из десятка заказов глаз находит грузовик и весы быстрее, чем
  /// читает «Отправлен — отметьте передачу». Берётся из [etStageIcon], чтобы у покупателя и у
  /// хозяйства один и тот же шаг выглядел одинаково.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final (Color bg, Color fg) = switch (tone) {
      'active' => (c.greenTint, c.green),
      'waiting' => (c.rustTint, c.rust),
      'danger' => (c.dangerTint, c.danger),
      'off' => (c.fillTrack, c.inkDim),
      _ => (c.fillTrack, c.inkDim),
    };
    final label = Text(
      text,
      style: context.texts.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w700),
    );
    return Container(
      padding: EdgeInsets.fromLTRB(icon == null ? 12 : 9, 6, 12, 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(EtShape.radiusPill)),
      child: icon == null
          ? label
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 6),
                Flexible(child: label),
              ],
            ),
    );
  }
}

/// A line of money or of facts: label on the left (with a quieter second line), value on the right.
class EtRow extends StatelessWidget {
  const EtRow({
    super.key,
    required this.label,
    this.sub,
    required this.value,
    this.strong = false,
    this.valueColor,
  });

  final String label;
  final String? sub;
  final String value;
  final bool strong;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: context.texts.bodyMedium?.copyWith(
                    fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                if (sub != null && sub!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(sub!, style: context.texts.bodySmall?.copyWith(color: c.inkFaint)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            textAlign: TextAlign.right,
            style: context.texts.bodyMedium?.copyWith(
              fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// Something the person should read before acting: a warning, a rule, a promise.
class EtNotice extends StatelessWidget {
  const EtNotice({super.key, required this.text, this.icon = Icons.info_outline, this.tone = 'info'});

  final String text;
  final IconData icon;

  /// info | danger
  final String tone;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final accent = tone == 'danger' ? c.danger : c.green;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tone == 'danger' ? c.dangerTint : c.greenTint,
        borderRadius: EtShape.smallRadius,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: context.texts.bodySmall?.copyWith(color: c.ink, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Nothing here yet - and what to do about it.
///
/// [illustrated] даёт экрану картинку вместо серого значка: ту самую степь, что открывает сайт, и
/// значок на её фоне. Пустая корзина, пустой список заказов, пустой каталог — это первое, что
/// многие увидят в приложении, и сорок серых пикселей на пустом листе выглядят как сбой, а не как
/// «здесь пока ничего». Второстепенным пустотам внутри карточек иллюстрация не нужна — там она
/// перетянет на себя весь экран.
class EtEmpty extends StatelessWidget {
  const EtEmpty({
    super.key,
    required this.title,
    this.text,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.illustrated = false,
  });

  final String title;
  final String? text;
  final IconData icon;
  final Widget? action;
  final bool illustrated;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (illustrated) ...[
              _Illustration(icon: icon),
              const SizedBox(height: 20),
            ] else ...[
              Icon(icon, size: 40, color: c.inkFaint),
              const SizedBox(height: 14),
            ],
            Text(title, textAlign: TextAlign.center, style: context.texts.titleMedium),
            if (text != null) ...[
              const SizedBox(height: 8),
              Text(
                text!,
                textAlign: TextAlign.center,
                style: context.texts.bodySmall?.copyWith(color: c.inkDim, height: 1.45),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}

/// Картинка пустого экрана: степной горизонт и значок на нём.
///
/// Полоса намеренно небольшая и лежит карточкой — это подпись к тексту, а не заставка.
class _Illustration extends StatelessWidget {
  const _Illustration({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return SizedBox(
      width: 232,
      height: 124,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ClipRRect(
              borderRadius: EtShape.cardRadius,
              child: const EtSteppe(height: 104),
            ),
          ),
          // Значок сидит на горизонте, наполовину съезжая с полосы: так он читается как предмет
          // на земле, а не как иконка, положенная поверх картинки.
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: c.surfaceRaised,
              shape: BoxShape.circle,
              border: Border.all(color: c.line),
              boxShadow: EtShape.soft(Theme.of(context).brightness == Brightness.dark),
            ),
            child: Icon(icon, size: 22, color: c.green),
          ),
        ],
      ),
    );
  }
}

/// The grey block that stands in for content while it loads. Quieter than a spinner, and it
/// keeps the layout from jumping when the data lands.
///
/// По блоку раз в полтора секунды проходит мягкий отблеск. Неподвижный серый прямоугольник в
/// половине случаев читается как «так и будет»: человек ждёт, а экран выглядит законченным.
/// Движение — единственное, что отличает «грузится» от «пусто», и стоит оно одного шейдера.
class EtSkeleton extends StatefulWidget {
  const EtSkeleton({super.key, this.height = 90, this.width = double.infinity});

  final double height;
  final double width;

  @override
  State<EtSkeleton> createState() => _EtSkeletonState();
}

class _EtSkeletonState extends State<EtSkeleton> with SingleTickerProviderStateMixin {
  late final _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void initState() {
    super.initState();
    _sweep.repeat();
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final base = c.fillTrack;
    final box = SizedBox(height: widget.height, width: widget.width);

    // Кому анимация мешает — тому ровный блок: системную настройку «убрать анимацию» ставят не
    // ради экономии батареи.
    if (MediaQuery.disableAnimationsOf(context)) {
      return DecoratedBox(
        decoration: BoxDecoration(color: base, borderRadius: EtShape.smallRadius),
        child: box,
      );
    }

    final highlight = Color.lerp(
      base,
      Theme.of(context).brightness == Brightness.dark ? c.surfaceRaised : Colors.white,
      Theme.of(context).brightness == Brightness.dark ? 0.55 : 0.85,
    )!;

    return AnimatedBuilder(
      animation: _sweep,
      builder: (context, _) {
        final x = _sweep.value * 3 - 1.5;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: EtShape.smallRadius,
            gradient: LinearGradient(
              begin: Alignment(x - 0.7, 0),
              end: Alignment(x + 0.7, 0),
              colors: [base, highlight, base],
              stops: const [0, 0.5, 1],
            ),
          ),
          child: box,
        );
      },
    );
  }
}

/// A small all-caps label above a heading, as on the website.
class EtEyebrow extends StatelessWidget {
  const EtEyebrow(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: context.texts.labelSmall?.copyWith(
          color: context.et.green,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      );
}

/// How much of a carcass is taken.
class EtProgress extends StatelessWidget {
  const EtProgress({
    super.key,
    required this.percent,
    this.label,
    this.trailing,
    this.tone = 'green',
  });

  /// Сколько занято: 0 — свободно всё, 1 — не осталось ничего.
  final double percent;
  final String? label;
  final String? trailing;

  /// green — обычный ход дела; rust — сбор, который ещё идёт.
  final String tone;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null || trailing != null)
          Padding(
            padding: EdgeInsets.only(bottom: percent > 0 ? 8 : 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(label ?? '', style: context.texts.bodySmall?.copyWith(color: c.inkDim)),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: context.texts.bodySmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
              ],
            ),
          ),
        // Пока не занято ничего, полосы нет вовсе. Пустая дорожка читается как «не загрузилось»,
        // а сказать «свободно всё» умеет подпись слева - шкала появляется тогда, когда ей есть
        // что показать. Заполненная целиком оставляет хвостик дорожки: «занято всё» должно
        // отличаться от «полоса просто зелёная».
        if (percent > 0)
          LayoutBuilder(
            builder: (context, box) {
              final value = percent.clamp(0.0, 1.0);
              final filled = (0.08 + value * 0.9).clamp(0.0, 0.97);
              return ClipRRect(
                borderRadius: BorderRadius.circular(EtShape.radiusPill),
                child: Container(
                  height: 8,
                  color: c.fillTrack,
                  child: Row(
                    children: [
                      Container(
                        width: box.maxWidth * filled,
                        decoration: BoxDecoration(
                          color: tone == 'rust' ? c.rust : c.green,
                          borderRadius: BorderRadius.circular(EtShape.radiusPill),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
