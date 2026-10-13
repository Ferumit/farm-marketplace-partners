import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Степь на закате — тот же рисунок, которым открывается сайт.
///
/// Это не «похожая картинка»: гребни считаются тем же способом и теми же числами, что и SVG на
/// главной, — сумма трёх синусов на слой, сглаженная Catmull-Rom в кубические кривые. Поэтому
/// холм, который человек видел вечером на сайте, он видит и в приложении, а не «что-то в том же
/// духе».
///
/// Четыре слоя, каждый темнее и ближе предыдущего, солнце низко над дальним гребнем, тёплая
/// подсветка кромок только с его стороны и дымка в ложбинах — именно кромка и дымка делают из
/// четырёх силуэтов землю, а не наклеенные друг на друга фигуры.
///
/// Рисунок векторный: ни одного килобайта в assets и любой размер без замыливания.
class EtSteppe extends StatelessWidget {
  const EtSteppe({super.key, this.height = 150, this.fadeTop = false});

  final double height;

  /// Растворить верх в фоне экрана. Нужно там, где полоса идёт сразу под содержимым: ровный
  /// тёмный край читался бы как оборвавшаяся картинка. Внизу экрана край честный — это горизонт.
  final bool fadeTop;

  @override
  Widget build(BuildContext context) {
    final art = SizedBox(
      height: height,
      width: double.infinity,
      child: const CustomPaint(painter: _SteppePainter(), isComplex: true, willChange: false),
    );
    if (!fadeTop) return art;
    return ShaderMask(
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black],
        stops: [0, 0.34],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: art,
    );
  }
}

/// Слой степи: высота гребня, три волны (амплитуда, длина, фаза) и его цвета.
class _Layer {
  const _Layer(this.base, this.waves, this.top, this.bottom, this.rim);

  final double base;
  final List<(double, double, double)> waves;
  final Color top;
  final Color bottom;

  /// Насколько ярко кромка ловит солнце: дальний гребень светится сильнее ближнего.
  final double rim;
}

const _layers = <_Layer>[
  _Layer(262, [(9, 1100, 0.6), (6, 430, 2.1), (2.2, 170, 0.3)], Color(0xFF6B523A), Color(0xFF5B4733), 0.60),
  _Layer(300, [(15, 900, 1.7), (8, 380, 0.4), (2.6, 150, 2.8)], Color(0xFF4A4331), Color(0xFF3A3628), 0.42),
  _Layer(344, [(19, 760, 3.1), (9, 320, 1.2), (3, 140, 0.9)], Color(0xFF2B3A2D), Color(0xFF213027), 0.30),
  _Layer(394, [(22, 1000, 0.2), (11, 420, 2.6), (3.4, 160, 1.9)], Color(0xFF152820), Color(0xFF0D1A15), 0.18),
];

/// Дымка в ложбине перед гребнем: (верх, низ, плотность) — числа из SVG сайта.
const _haze = <(double, double, double)>[(256, 310, 0.20), (294, 354, 0.10), (338, 404, 0.10)];

class _SteppePainter extends CustomPainter {
  const _SteppePainter();

  /// Система координат рисунка — тот же viewBox, что на сайте.
  static const _w = 1600.0;
  static const _h = 460.0;
  static const _sunX = 1130.0;
  static const _sunR = 30.0;

  /// Небо. На сайте оно живёт в CSS, и его стопы заданы в долях полосы рисунка; здесь полоса и
  /// есть весь кадр, поэтому весь ход от тёплой земли до сумеречной зелени укладывается в него.
  static const _sky = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF0B1D18),
      Color(0xFF152A22),
      Color(0xFF33362A),
      Color(0xFF6E5139),
      Color(0xFFA87448),
      Color(0xFFA87448),
    ],
    stops: [0, 0.086, 0.343, 0.543, 0.686, 1],
  );

  static double _yAt(_Layer layer, double x) {
    var sum = 0.0;
    for (final (amplitude, wave, phase) in layer.waves) {
      sum += amplitude * math.sin(2 * math.pi * x / wave + phase);
    }
    return layer.base - sum;
  }

  /// Гребень через Catmull-Rom: по точкам раз в 50 единиц строятся кубические кривые, и холмы
  /// получаются пологими перекатами, а не ломаной.
  static Path _crest(_Layer layer) {
    final points = <Offset>[];
    for (var x = -100.0; x <= _w + 100; x += 50) {
      points.add(Offset(x, _yAt(layer, x)));
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[math.max(0, i - 1)];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = points[math.min(points.length - 1, i + 2)];
      path.cubicTo(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
        p2.dx,
        p2.dy,
      );
    }
    return path;
  }

  /// Кривые одинаковы на каждом кадре и на каждом экране — считаются один раз за запуск.
  static final _crests = _layers.map(_crest).toList(growable: false);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    // Как preserveAspectRatio="xMidYMax slice" на сайте: рисунок накрывает кадр целиком,
    // прижат к низу и обрезан по бокам поровну.
    final scale = math.max(size.width / _w, size.height / _h);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate((size.width - _w * scale) / 2, size.height - _h * scale);
    canvas.scale(scale);

    const frame = Rect.fromLTWH(0, 0, _w, _h);
    final sunY = _yAt(_layers.first, _sunX) + 9;

    canvas.drawRect(frame, Paint()..shader = _sky.createShader(frame));

    // Тепло, разлитое вокруг солнца: широкое и плоское, поэтому гаснет задолго до верха кадра.
    canvas.drawRect(
      frame,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(_sunX, sunY),
          1,
          const [Color(0x9EFFC985), Color(0x42EE9A58), Color(0x00EE9A58)],
          const [0, 0.3, 1],
          TileMode.clamp,
          _ellipse(_sunX, sunY, 460, 150),
        ),
    );

    canvas.drawCircle(Offset(_sunX, sunY), _sunR + 14, Paint()..color = const Color(0x2EFFD29A));
    canvas.drawCircle(
      Offset(_sunX, sunY),
      _sunR,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFFFFE3B0), Color(0xFFFFC77E), Color(0xFFF4A860)],
          stops: [0, 0.7, 1],
        ).createShader(Rect.fromCircle(center: Offset(_sunX, sunY), radius: _sunR)),
    );

    for (var i = 0; i < _layers.length; i++) {
      final layer = _layers[i];
      final crest = _crests[i];

      // Заливка гребня: у кромки светлее, к подножию уходит в тень.
      final lowest = layer.base - layer.waves.map((w) => w.$1).reduce(math.max) * 2.2;
      final body = Path.from(crest)
        ..lineTo(_w + 100, _h + 10)
        ..lineTo(-100, _h + 10)
        ..close();
      canvas.drawPath(
        body,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, lowest),
            const Offset(0, _h),
            [layer.top, layer.bottom],
          ),
      );

      // Свет по кромке — только со стороны солнца. Без него слои читаются плоскими вырезками.
      canvas.drawPath(
        crest,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..shader = ui.Gradient.linear(
            const Offset(_sunX - 700, 0),
            const Offset(_sunX + 700, 0),
            [
              const Color(0xFFFFC98A).withValues(alpha: 0),
              const Color(0xFFFFC98A).withValues(alpha: layer.rim),
              const Color(0xFFFFC98A).withValues(alpha: 0),
            ],
            const [0, 0.5, 1],
          ),
      );

      if (i < _haze.length) {
        final (top, bottom, alpha) = _haze[i];
        canvas.drawRect(
          Rect.fromLTRB(0, top, _w, bottom),
          Paint()
            ..shader = ui.Gradient.linear(
              Offset(0, top),
              Offset(0, bottom),
              [
                const Color(0xFFD9A36E).withValues(alpha: 0),
                const Color(0xFFD9A36E).withValues(alpha: alpha),
              ],
            ),
        );
      }
    }

    canvas.restore();
  }

  /// Матрица «растянуть градиент в эллипс вокруг точки» — то же, что gradientTransform в SVG.
  static Float64List _ellipse(double x, double y, double rx, double ry) => Float64List.fromList([
        rx, 0, 0, 0, //
        0, ry, 0, 0, //
        0, 0, 1, 0, //
        x - rx * x, y - ry * y, 0, 1,
      ]);

  @override
  bool shouldRepaint(covariant _SteppePainter oldDelegate) => false;
}
