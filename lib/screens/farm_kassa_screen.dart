import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';

/// «Онлайн-касса» — подключение кассы хозяйства, которой платформа выбивает чеки.
///
/// Продавец мяса — хозяйство, а не платформа, поэтому и чек должен выйти под его БИН. Касса
/// остаётся у фермера: он регистрирует её своей ЭЦП и разрешает нашему приложению ей
/// пользоваться. Мы храним только доступ.
///
/// Пароль и ПИН обратно не показываются никогда — ни фермеру, ни администратору: это
/// действующие ключи, которыми выбиваются налоговые документы. Экран знает лишь заводской
/// номер и то, что подключение есть.
class FarmKassaScreen extends StatefulWidget {
  const FarmKassaScreen({super.key});

  @override
  State<FarmKassaScreen> createState() => _FarmKassaScreenState();
}

class _FarmKassaScreenState extends State<FarmKassaScreen> {
  final _farms = FarmRepo();
  final _znm = TextEditingController();
  final _password = TextEditingController();
  final _pin = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _connectedZnm;

  String? get _uid => context.read<AuthService>().uid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _znm.dispose();
    _password.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final info = await _farms.readPrivate(uid, Paths.privateKassaInfo);
      if (!mounted) return;
      setState(() {
        _connectedZnm = asTextOrNull(info?['znm']);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить. Проверьте связь.';
      });
    }
  }

  Future<void> _save() async {
    final uid = _uid;
    if (uid == null) return;
    final znm = _znm.text.trim().toUpperCase();
    final password = _password.text.trim();
    final pin = _pin.text.trim();

    if (!RegExp(r'^[A-Za-z0-9-]{4,40}$').hasMatch(znm)) {
      setState(() => _error = 'Заводской номер — буквы, цифры и дефис, как в приложении кассы.');
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = 'Вставьте пароль, который выдала re:Kassa.');
      return;
    }
    if (!RegExp(r'^[0-9]{4,6}$').hasMatch(pin)) {
      setState(() => _error = 'ПИН кассы — от четырёх до шести цифр.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _farms.saveKassa(uid, znm: znm, password: password, pin: pin);
      if (!mounted) return;
      // Поля чистим сразу: показывать их дальше незачем, а пароль в поле — лишний риск.
      _password.clear();
      _pin.clear();
      setState(() {
        _saving = false;
        _connectedZnm = znm;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Касса подключена. Чеки будут выбиваться автоматически.')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Не удалось сохранить. Проверьте связь.';
      });
    }
  }

  Future<void> _disconnect() async {
    final uid = _uid;
    if (uid == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Отключить кассу?'),
        content: const Text('Чеки перестанут выбиваться, а выдавать их при расчёте с покупателем '
            'обязывает закон. Подключить обратно можно в любой момент — понадобится новый пароль.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Назад')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Отключить')),
        ],
      ),
    );
    if (ok != true) return;
    await _farms.removeKassa(uid);
    if (!mounted) return;
    setState(() => _connectedZnm = null);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Онлайн-касса'),
        actions: const [EtHelpButton(articleId: 'kassa')],
      ),
      body: _loading
          ? const Padding(
              padding: EdgeInsets.all(EtShape.gutter),
              child: EtSkeleton(height: 200),
            )
          : ListView(
              padding: const EdgeInsets.all(EtShape.gutter),
              children: [
                EtNotice(
                  text: _connectedZnm != null
                      ? 'Касса подключена: ${_connectedZnm!}. Чеки по вашим заказам выбиваются '
                          'автоматически и выходят под вашим БИН.'
                      : 'Продавец мяса — вы, значит и чек ваш. Подключите свою кассу, и платформа '
                          'будет выбивать чеки от вашего имени: сама, в момент оплаты.',
                  icon: _connectedZnm != null ? Icons.verified_outlined : Icons.receipt_long_outlined,
                ),
                const SizedBox(height: EtShape.gap),

                EtCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Что сделать в re:Kassa', style: context.texts.titleSmall),
                      const SizedBox(height: 10),
                      const _Step(1, 'Зарегистрируйте кассу в приложении re:Kassa — понадобится '
                          'ваша ЭЦП. Касса остаётся вашей, мы ею только пользуемся.'),
                      const _Step(2, 'Настройки → «Подключить приложение» → выберите '
                          '«ТОО Компания» → «Получить пароль».'),
                      const _Step(3, 'Пароль показывается один раз. Скопируйте его и перенесите '
                          'сюда вместе с заводским номером и ПИН-кодом кассы.'),
                    ],
                  ),
                ),
                const SizedBox(height: EtShape.gap),

                EtCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_connectedZnm != null ? 'Заменить доступ' : 'Доступ к кассе',
                          style: context.texts.titleSmall),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _znm,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'Заводской номер кассы (ЗНМ)',
                          hintText: 'TESTZNM-000',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _password,
                        decoration: const InputDecoration(
                          labelText: 'Пароль для приложения',
                          helperText: 'Тот, что показали один раз в re:Kassa',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _pin,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'ПИН-код кассы',
                          helperText: 'Им закрывается смена в конце дня',
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Пароль и ПИН мы не покажем обратно — ни вам, ни администратору. Это '
                        'ключи, которыми выбиваются налоговые документы от вашего имени, и '
                        'лежать на виду они не должны.',
                        style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
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
                  onPressed: _saving ? null : _save,
                  child: Text(_saving
                      ? 'Сохраняем…'
                      : _connectedZnm != null ? 'Заменить доступ' : 'Подключить кассу'),
                ),
                if (_connectedZnm != null) ...[
                  const SizedBox(height: 10),
                  TextButton(onPressed: _disconnect, child: const Text('Отключить кассу')),
                ],
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.text);

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.greenTint, shape: BoxShape.circle),
            child: Text('$number',
                style: context.texts.bodySmall?.copyWith(color: c.green, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(text, style: context.texts.bodyMedium?.copyWith(height: 1.45)),
            ),
          ),
        ],
      ),
    );
  }
}
