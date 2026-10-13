import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Содержимое не подменяет скелетон рывком, а приходит: проявляется и чуть поднимается.
///
/// Момент, когда данные долетели, — единственный, где приложение может показать, что оно работало,
/// а не зависло. Раньше серые блоки в одном кадре заменялись карточками, и это читалось как
/// перескок склейки: глаз не успевал понять, то же это место или уже другое.
///
/// Карточки в списке выходят по очереди — [index] задаёт задержку, но только первым нескольким.
/// Дальше задержка перестаёт расти: на первом экране видно четыре-пять карточек, и заставлять
/// десятую ждать полсекунды было бы издевательством над тем, кто пролистнул сразу вниз.
class EtReveal extends StatefulWidget {
  const EtReveal({super.key, required this.child, this.index = 0});

  final Widget child;

  /// Место в списке. Первые [_staggered] штук выходят одна за другой, остальные — сразу.
  final int index;

  @override
  State<EtReveal> createState() => _EtRevealState();
}

/// Сколько карточек выходят по очереди и с каким шагом.
const _staggered = 5;
const _step = 45;
const _travel = 260;

class _EtRevealState extends State<EtReveal> with SingleTickerProviderStateMixin {
  late final int _delay = math.min(widget.index, _staggered) * _step;

  /// Задержка живёт внутри самой анимации, а не в таймере: таймер пришлось бы отменять при
  /// уходе с экрана, и забытый — это кадр, нарисованный в выброшенное дерево.
  late final _run = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: _delay + _travel),
  )..forward();

  late final _curve = CurvedAnimation(
    parent: _run,
    curve: Interval(_delay / (_delay + _travel), 1, curve: Curves.easeOutCubic),
  );

  @override
  void dispose() {
    _curve.dispose();
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Кому анимация мешает — тому сразу содержимое.
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;

    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(_curve),
        child: widget.child,
      ),
    );
  }
}
