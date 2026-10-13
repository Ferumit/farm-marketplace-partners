import 'package:et_ui/et_ui.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/firestore_service.dart';

/// Регистрация хозяйства: кто вы, куда прислать код, и на этом всё.
///
/// Переписана на общую дизайн-систему. Порядок шагов прежний и он важен: сначала данные, потом
/// подтверждение номера, и только после подтверждения запись — иначе в базе оставались бы
/// хозяйства без владельца.
///
/// ИИН/БИН уходит в приватную запись хозяйства, а не в профиль, который читают покупатели.
/// Статус, рейтинг и балансы отсюда не отправляются вовсе: хозяйство, регистрирующееся заново,
/// не должно уметь сбросить свою же проверку.
class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

enum _Step { details, code }

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _name = TextEditingController();
  final _iin = TextEditingController();
  final _city = TextEditingController();
  final _phone = TextEditingController(text: '+7');
  final _code = TextEditingController();

  _Step _step = _Step.details;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final field in [_name, _iin, _city, _phone, _code]) {
      field.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final field in [_name, _iin, _city, _phone, _code]) {
      field.dispose();
    }
    super.dispose();
  }

  String get _digits => _phone.text.replaceAll(RegExp(r'[^0-9+]'), '');

  bool get _detailsReady =>
      _name.text.trim().length >= 2 &&
      _iin.text.trim().length == 12 &&
      _digits.replaceAll('+', '').length >= 10;

  Future<void> _sendCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sent = await context.read<AuthService>().sendOtp(_digits);
      if (!mounted) return;
      if (sent) {
        setState(() => _step = _Step.code);
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

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = context.read<AuthService>();
      final firestore = context.read<FirestoreService>();

      // Android умеет прочитать SMS и войти сам. Тогда проверять код второй раз нельзя: сессия
      // уже израсходована, и Firebase ответит «сессия истекла» на верный код. Вошли — значит
      // остаётся только записать хозяйство.
      final ok = auth.isLoggedIn ? true : await auth.verifyOtp(_code.text.trim());
      if (!mounted) return;

      if (ok && auth.uid != null) {
        await firestore.registerFarm(
          uid: auth.uid!,
          phone: auth.phone ?? _digits,
          displayName: _name.text.trim(),
          city: _city.text.trim().isEmpty ? null : _city.text.trim(),
          iin: _iin.text.trim(),
        );
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      } else {
        setState(() => _error = auth.error ?? 'Неверный код.');
      }
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(e, st, fatal: false);
      if (mounted) setState(() => _error = 'Не удалось сохранить. Проверьте связь.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final onDetails = _step == _Step.details;

    return Scaffold(
      appBar: AppBar(
        leading: onDetails
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _step = _Step.details;
                  _error = null;
                  _code.clear();
                }),
              ),
        title: Text(onDetails ? 'Регистрация хозяйства' : 'Код из SMS'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(EtShape.gutter),
        children: [
          if (onDetails) ...[
            const EtNotice(
              text: 'После регистрации хозяйство проверяет администратор. Скот, документы и лоты '
                  'можно готовить сразу — покупатели увидят их после подтверждения.',
              icon: Icons.hourglass_empty,
            ),
            const SizedBox(height: EtShape.gap),
            EtCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Хозяйство', style: context.texts.titleSmall),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _name,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      labelText: 'Название',
                      hintText: 'КХ «Тулпар»',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _city,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      labelText: 'Город или область',
                      hintText: 'Акмолинская область',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _iin,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(12),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'ИИН или БИН',
                      helperText: '12 цифр. Видят только вы и администратор',
                      counterText: '',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: EtShape.gap),
            EtCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Телефон', style: context.texts.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    'На него придёт код и по нему вы входите в кабинет. Его же увидит покупатель '
                    'в своём заказе.',
                    style: context.texts.bodySmall?.copyWith(color: c.inkDim),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s()-]')),
                      LengthLimitingTextInputFormatter(20),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Номер',
                      hintText: '+7 700 000 00 00',
                      prefixIcon: Icon(Icons.phone_outlined),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            Text('Введите код', style: context.texts.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Отправили на ${_phone.text}. Шесть цифр.',
              style: context.texts.bodyMedium?.copyWith(color: c.inkDim),
            ),
            const SizedBox(height: 20),
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
          ],

          if (_error != null) ...[
            const SizedBox(height: EtShape.gap),
            EtNotice(text: _error!, icon: Icons.error_outline, tone: 'danger'),
          ],

          const SizedBox(height: EtShape.gap),
          FilledButton(
            onPressed: _busy || (onDetails ? !_detailsReady : _code.text.trim().length != 6)
                ? null
                : (onDetails ? _sendCode : _confirm),
            child: Text(
              _busy
                  ? 'Минуту…'
                  : (onDetails ? 'Получить код' : 'Зарегистрировать хозяйство'),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
