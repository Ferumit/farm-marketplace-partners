import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';

/// «Реквизиты» - the legal form, the registered name and address, the ИИН/БИН and the email for
/// order notifications.
///
/// None of it sits on the public profile: buyers read `partners/{uid}`, and the ИИН has no
/// business being there (an older version of this app put it there). It lives in
/// partners/{uid}/private/*, readable by the farm and by staff alone.
class FarmLegalScreen extends StatefulWidget {
  const FarmLegalScreen({super.key});

  @override
  State<FarmLegalScreen> createState() => _FarmLegalScreenState();
}

class _FarmLegalScreenState extends State<FarmLegalScreen> {
  final _farms = FarmRepo();
  final _legalName = TextEditingController();
  final _address = TextEditingController();
  final _iin = TextEditingController();
  final _email = TextEditingController();
  final _iban = TextEditingController();
  final _bic = TextEditingController();
  final _bankName = TextEditingController();
  final _kbe = TextEditingController();

  String _form = legalForms.first.id;
  Partner? _farm;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  String? get _uid => context.read<AuthService>().uid;

  /// After approval the ИИН and the legal details are part of what was checked, so changing them
  /// goes through staff - the rules say the same, and a field that looks editable but refuses to
  /// save is worse than one that says why.
  bool get _locked => farmSells(_farm?.status ?? '');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _legalName.dispose();
    _address.dispose();
    _iin.dispose();
    _email.dispose();
    _iban.dispose();
    _bic.dispose();
    _bankName.dispose();
    _kbe.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final farm = await _farms.read(uid);
      final legal = await _farms.readPrivate(uid, Paths.privateLegal);
      final identity = await _farms.readPrivate(uid, Paths.privateIdentity);
      final contact = await _farms.readPrivate(uid, Paths.privateContact);
      final bank = await _farms.readPrivate(uid, Paths.privateBank);
      if (!mounted) return;
      setState(() {
        _iban.text = asText(bank?['iban']);
        _bic.text = asText(bank?['bic']);
        _bankName.text = asText(bank?['bankName']);
        _kbe.text = asText(bank?['kbe']);
        _farm = farm;
        _form = asTextOrNull(legal?['form']) ?? legalForms.first.id;
        _legalName.text = asText(legal?['legalName']);
        _address.text = asText(legal?['address']);
        _iin.text = asText(identity?['iin']);
        _email.text = asText(contact?['email']);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить реквизиты. Проверьте связь.';
      });
    }
  }

  Future<void> _save() async {
    final uid = _uid;
    if (uid == null) return;
    final legalName = _legalName.text.trim();
    final address = _address.text.trim();
    final iin = _iin.text.trim();
    final email = _email.text.trim();

    if (!_locked) {
      if (legalName.length < 2) {
        setState(() => _error = 'Укажите название так, как оно записано в документах.');
        return;
      }
      if (address.length < 5) {
        setState(() => _error = 'Укажите адрес регистрации.');
        return;
      }
      if (iin.length != 12 || int.tryParse(iin) == null) {
        setState(() => _error = 'ИИН или БИН — 12 цифр.');
        return;
      }
    }
    if (email.isNotEmpty && !email.contains('@')) {
      setState(() => _error = 'Проверьте адрес почты.');
      return;
    }

    // Счёт — целиком или никак. Половина реквизитов хуже их отсутствия: по такому счёту деньги
    // не уйдут, а выглядеть он будет заполненным.
    final iban = _iban.text.trim().replaceAll(' ', '').toUpperCase();
    final bic = _bic.text.trim().toUpperCase();
    final bankName = _bankName.text.trim();
    final kbe = _kbe.text.trim();
    final bankFilled = [iban, bic, bankName, kbe].where((v) => v.isNotEmpty).length;
    if (bankFilled > 0 && bankFilled < 4) {
      setState(() => _error = 'Заполните счёт целиком: IBAN, БИК, банк и КБе.');
      return;
    }
    if (bankFilled == 4) {
      if (!RegExp(r'^KZ[0-9A-Z]{18}$').hasMatch(iban)) {
        setState(() => _error = 'IBAN в Казахстане — KZ и ещё 18 знаков.');
        return;
      }
      if (!RegExp(r'^[A-Z0-9]{8}$').hasMatch(bic)) {
        setState(() => _error = 'БИК банка — 8 знаков.');
        return;
      }
      if (!RegExp(r'^[0-9]{2}$').hasMatch(kbe)) {
        setState(() => _error = 'КБе — две цифры.');
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (!_locked) {
        await _farms.saveLegal(uid, form: _form, legalName: legalName, address: address);
        await _farms.saveIin(uid, iin);
      }
      await _farms.saveContactEmail(uid, email.isEmpty ? null : email);
      if (bankFilled == 4) {
        await _farms.saveBank(uid, iban: iban, bic: bic, bankName: bankName, kbe: kbe);
      }
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Реквизиты сохранены.')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Не удалось сохранить. Проверьте связь.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Реквизиты'),
        actions: const [EtHelpButton(articleId: 'legal')],
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
                  text: _locked
                      ? 'Хозяйство проверено — реквизиты и ИИН менять может только администратор. '
                          'Напишите в поддержку, если они изменились.'
                      : 'Эти данные видят только вы и администратор. Покупателям они не '
                          'показываются.',
                  icon: _locked ? Icons.lock_outline : Icons.shield_outlined,
                ),
                const SizedBox(height: EtShape.gap),
                EtCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Хозяйство по документам', style: context.texts.titleSmall),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _form,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Форма'),
                        items: [
                          for (final form in legalForms)
                            DropdownMenuItem(
                              value: form.id,
                              child: Text(form.label, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: _locked ? null : (value) => setState(() => _form = value ?? _form),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _legalName,
                        enabled: !_locked,
                        maxLength: 160,
                        decoration: const InputDecoration(
                          labelText: 'Название по документам',
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _address,
                        enabled: !_locked,
                        maxLines: 2,
                        maxLength: 300,
                        decoration: const InputDecoration(
                          labelText: 'Адрес регистрации',
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _iin,
                        enabled: !_locked,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(12),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'ИИН или БИН',
                          helperText: '12 цифр',
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
                      Text('Почта для заказов', style: context.texts.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                        'Необязательно. Если указать — письмо о новом заказе придёт туда же, '
                        'куда приходит уведомление в приложении.',
                        style: context.texts.bodySmall?.copyWith(color: c.inkDim),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: 'Электронная почта'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: EtShape.gap),
                EtCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Счёт — вторая, отдельная работа на этом экране, и спрашивают о нём чаще,
                      // чем о названии по документам. Своя подсказка стоит прямо над полями:
                      // «?» в шапке человек к этому моменту уже пролистал.
                      Row(
                        children: [
                          Expanded(
                            child: Text('Счёт для выплат', style: context.texts.titleSmall),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              final article = helpArticle('bank');
                              if (article != null) showHelpArticle(context, article);
                            },
                            icon: const Icon(Icons.help_outline, size: 16),
                            label: const Text('Как заполнить'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Сюда платформа перечислит вашу долю: 50 % при принятии заказа, '
                        '25 % когда мясо готово и 25 % после завершения сделки. Счёт должен быть '
                        'открыт на то же лицо, что указано выше.',
                        style: context.texts.bodySmall?.copyWith(color: c.inkDim),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _iban,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'IBAN',
                          hintText: 'KZ00 000 0000 0000 0000',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _bankName,
                        decoration: const InputDecoration(labelText: 'Банк'),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _bic,
                              textCapitalization: TextCapitalization.characters,
                              decoration: const InputDecoration(labelText: 'БИК'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _kbe,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(labelText: 'КБе'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Выплаты на счёт — следующий этап: пока деньги по заказу держит '
                        'платформа, а на экране заказа виден план по шагам. Счёт можно заполнить '
                        'заранее и менять когда угодно, проверки для этого не нужно.',
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
                  child: Text(_saving ? 'Сохраняем…' : 'Сохранить'),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
