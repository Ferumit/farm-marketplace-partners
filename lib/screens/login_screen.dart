import 'dart:async';

import 'package:et_ui/et_ui.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';

/// Вход по номеру телефона.
///
/// Два шага и ни одного лишнего: номер — код. Раньше экран жил вне дизайн-системы, со своей
/// палитрой и своими шрифтами; теперь он на общей теме.
///
/// Номер хранится как есть, без маски «+7 » в самом поле: маска мешала вставить номер из буфера
/// и ломала любой номер, кроме казахстанского, — включая тестовые, которыми проверяют приложение.
/// Код страны предлагается, но не навязывается.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _Step { phone, code }

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController(text: '+7');
  final _code = TextEditingController();

  _Step _step = _Step.phone;
  bool _busy = false;
  String? _error;
  int _resendIn = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _phone.addListener(() => setState(() {}));
    _code.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _digits => _phone.text.replaceAll(RegExp(r'[^0-9+]'), '');
  bool get _phoneReady => _digits.replaceAll('+', '').length >= 10;
  bool get _codeReady => _code.text.trim().length == 6;

  void _countdown() {
    setState(() => _resendIn = 60);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      if (_resendIn > 0) {
        setState(() => _resendIn--);
      } else {
        timer.cancel();
      }
    });
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sent = await context.read<AuthService>().sendOtp(_digits);
      if (!mounted) return;
      if (sent) {
        setState(() => _step = _Step.code);
        _countdown();
      } else {
        setState(() => _error = context.read<AuthService>().error ?? 'Не удалось отправить код.');
      }
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(e, st, fatal: false);
      if (mounted) setState(() => _error = 'Не получилось. Проверьте связь.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await context.read<AuthService>().verifyOtp(_code.text.trim());
      if (!mounted) return;
      if (ok) {
        Navigator.of(context, rootNavigator: true).pop();
      } else {
        final problem = context.read<AuthService>().error ?? 'Неверный код.';
        setState(() {
          _error = problem;
          // Если сессия кончилась, ждать отсчёта незачем - код уже не проверить.
          if (problem.contains('истекла')) {
            _timer?.cancel();
            _resendIn = 0;
            _code.clear();
          }
        });
      }
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(e, st, fatal: false);
      if (mounted) setState(() => _error = 'Не получилось проверить код. Проверьте связь.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Android умеет прочитать SMS сам и войти без нашей кнопки. Тогда экран входа остаётся
  /// висеть поверх приложения, человек набирает код руками — а сессия уже израсходована, и
  /// Firebase отвечает «сессия истекла». Поэтому вошедшего отсюда уводим сразу.
  void _closeIfSignedIn(bool signedIn) {
    if (!signedIn || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final onPhone = _step == _Step.phone;
    _closeIfSignedIn(context.watch<AuthService>().isLoggedIn);

    return Scaffold(
      appBar: AppBar(
        leading: onPhone
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _step = _Step.phone;
                  _error = null;
                  _code.clear();
                }),
              ),
        title: Text(onPhone ? 'Вход' : 'Код из SMS'),
      ),
      // Степь у нижнего края: экран входа — это ожидание SMS на пустом листе, и полоса горизонта
      // занимает его тем же рисунком, которым сайт встречает человека. Пока открыта клавиатура,
      // места нет — полоса уходит, а не сминается.
      body: Column(
        children: [
          Expanded(child: _form(context, onPhone)),
          if (MediaQuery.viewInsetsOf(context).bottom == 0) const EtSteppe(height: 132),
        ],
      ),
    );
  }

  Widget _form(BuildContext context, bool onPhone) {
    final c = context.et;
    return ListView(
      padding: const EdgeInsets.all(EtShape.gutter),
      children: [
        const SizedBox(height: 8),
        Text(
          onPhone ? 'Номер телефона' : 'Введите код',
          style: context.texts.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          onPhone
              ? 'На него придёт код из SMS. Этим же номером вы входите в кабинет хозяйства.'
              : 'Отправили на ${_phone.text}. Код из шести цифр.',
          style: context.texts.bodyMedium?.copyWith(color: c.inkDim),
        ),
        const SizedBox(height: 20),

        if (onPhone)
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            autofocus: true,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s()-]')),
              LengthLimitingTextInputFormatter(20),
            ],
            decoration: const InputDecoration(
              labelText: 'Телефон',
              hintText: '+7 700 000 00 00',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          )
        else
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            autofocus: true,
            textAlign: TextAlign.center,
            style: context.texts.headlineSmall?.copyWith(letterSpacing: 8),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: const InputDecoration(hintText: '••••••', counterText: ''),
          ),

        if (_error != null) ...[
          const SizedBox(height: EtShape.gap),
          EtNotice(text: _error!, icon: Icons.error_outline, tone: 'danger'),
        ],

        const SizedBox(height: EtShape.gap),
        FilledButton(
          onPressed: _busy || (onPhone ? !_phoneReady : !_codeReady)
              ? null
              : (onPhone ? _send : _verify),
          child: Text(_busy ? 'Минуту…' : (onPhone ? 'Получить код' : 'Войти')),
        ),

        if (!onPhone) ...[
          const SizedBox(height: 10),
          Center(
            child: TextButton(
              onPressed: _resendIn > 0 || _busy ? null : _send,
              child: Text(_resendIn > 0 ? 'Отправить снова через $_resendIn с' : 'Отправить снова'),
            ),
          ),
        ],

        const SizedBox(height: 18),
        Text(
          'Продолжая, вы соглашаетесь с условиями использования и политикой '
          'конфиденциальности ET Partners.',
          textAlign: TextAlign.center,
          style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
        ),
      ],
    );
  }
}
