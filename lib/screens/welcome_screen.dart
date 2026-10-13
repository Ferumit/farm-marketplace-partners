import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';

import 'login_screen.dart';
import 'registration_screen.dart';

/// Первый экран приложения хозяйства.
///
/// Раньше он жил вне дизайн-системы — на CupertinoPageScaffold, со своей палитрой и обещаниями
/// вроде «масштабируй бизнес». Теперь он на общей теме и говорит то, что платформа действительно
/// делает для хозяйства: показывает заказ, ведёт его по шагам и платит частями.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.et;

    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.sizeOf(context).height * 0.52,
            child: ShaderMask(
              shaderCallback: (rect) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black, Colors.black, Colors.transparent],
                stops: const [0, 0.5, 1],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: Image.asset(
                'assets/images/steppe_horses_background.png',
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => ColoredBox(color: c.greenTint),
              ),
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: EtShape.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  _brand(context),
                  const Spacer(),
                  Text(
                    'Продавайте тушу\nнапрямую.',
                    style: context.texts.displaySmall?.copyWith(height: 1.05),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Заказ приходит в телефон, вы ведёте его по четырём шагам и получаете деньги '
                    'частями — без посредников между вами и покупателем.',
                    style: context.texts.bodyMedium?.copyWith(color: c.inkDim, height: 1.5),
                  ),
                  const SizedBox(height: 24),
                  _promises(context),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const RegistrationScreen()),
                    ),
                    child: const Text('Зарегистрировать хозяйство'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                    ),
                    child: const Text('У меня уже есть аккаунт'),
                  ),
                  const SizedBox(height: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _brand(BuildContext context) {
    final c = context.et;
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(color: c.green, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text(
            'ET',
            style: context.texts.labelLarge?.copyWith(color: c.onGreen, letterSpacing: 0.5),
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('ET Partners', style: context.texts.titleMedium?.copyWith(color: c.green)),
            Text(
              'для хозяйств',
              style: context.texts.labelSmall?.copyWith(color: c.inkFaint, letterSpacing: 1.2),
            ),
          ],
        ),
      ],
    );
  }

  Widget _promises(BuildContext context) {
    const items = [
      (Icons.receipt_long_outlined, 'Заказ в телефоне', 'Кто, что и куда — сразу с контактами'),
      (Icons.payments_outlined, 'Деньги частями', '50 % при подтверждении, 25 % и 25 % дальше'),
      (Icons.verified_outlined, 'Проверка один раз', 'СЭС и ветконтроль — и вы в каталоге'),
    ];

    final c = context.et;
    return Column(
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Icon(item.$1, size: 20, color: c.green),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.$2,
                        style: context.texts.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        item.$3,
                        style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
