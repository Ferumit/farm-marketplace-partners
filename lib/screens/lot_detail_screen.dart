import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';

/// Лот глазами хозяйства: что выставлено, сколько разобрано и что с этим можно сделать.
///
/// Переписан на общую дизайн-систему и на общую модель: экран берёт лот по id и читает его
/// заново, а не получает готовый объект. Так список и страница не расходятся, когда покупатель
/// бронирует долю в ту же секунду.
///
/// Действия — это состояния лота, а не кнопки ради кнопок: черновик публикуют, открытый лот
/// можно вернуть в черновик, пока его не забронировали, забронированный отправляют, отправленный
/// закрывают. Лот, в котором есть чужие деньги, редактировать нельзя — это же говорят и правила.
class LotDetailScreen extends StatefulWidget {
  const LotDetailScreen({super.key, required this.lotId});

  final String lotId;

  @override
  State<LotDetailScreen> createState() => _LotDetailScreenState();
}

class _LotDetailScreenState extends State<LotDetailScreen> {
  final _catalogue = CatalogueRepo();
  final _farms = FarmRepo();

  Lot? _lot;
  Map<String, Animal> _animals = const {};
  bool _loading = true;
  bool _busy = false;
  String? _error;

  static const _status = {
    'draft': ('Черновик', 'off'),
    'open': ('В продаже', 'active'),
    'fully_booked': ('Забронирована', 'waiting'),
    'in_transit': ('В пути', 'waiting'),
    'sold': ('Продана', 'off'),
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final lot = await _catalogue.lot(widget.lotId);
      final animals = lot == null
          ? <String, Animal>{}
          : await _catalogue.animalsByIds(lot.animalIds);
      if (!mounted) return;
      setState(() {
        _lot = lot;
        _animals = animals;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Не удалось загрузить лот. Проверьте связь.';
        });
      }
    }
  }

  Future<void> _setStatus(String status) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _farms.setLotStatus(widget.lotId, status);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось изменить состояние лота.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить лот?'),
        content: const Text('Туша исчезнет из каталога. Животные и документы останутся на месте.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Назад')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _farms.deleteLot(widget.lotId);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось удалить лот.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final lot = _lot;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Лот'),
        actions: [
          if (lot != null && lot.bookedShares == 0 && lot.status != 'sold')
            IconButton(
              tooltip: 'Удалить лот',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: _loading
          ? const Padding(
              padding: EdgeInsets.all(EtShape.gutter),
              child: EtSkeleton(height: 220),
            )
          : lot == null
              ? const EtEmpty(
                  title: 'Лот не найден',
                  text: 'Возможно, его уже удалили.',
                  icon: Icons.search_off,
                )
              : _body(lot),
      bottomNavigationBar: lot == null ? null : _actions(lot),
    );
  }

  Widget _body(Lot lot) {
    final c = context.et;
    final taken = lot.totalShares == 0 ? 0.0 : lot.bookedShares / lot.totalShares;
    final state = _status[lot.status] ?? ('Черновик', 'off');
    final offers = formatsOf(lot);
    final animal = _animals.values.isEmpty ? null : _animals.values.first;

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        EtHero(
          label: meatLabel[animal?.type ?? lot.meatType ?? 'cattle'] ?? 'Мясо',
          meatType: animal?.type ?? lot.meatType ?? 'cattle',
          imageUrl: lot.imageUrl,
          height: 110,
          rounded: false,
          note: lot.totalWeight > 0 ? weightLabel(lot.totalWeight) : null,
        ),
        Padding(
          padding: const EdgeInsets.all(EtShape.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(lot.name, style: context.texts.headlineSmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  EtStatusChip(text: state.$1, tone: state.$2),
                  const SizedBox(width: 8),
                  if (lot.location != null && lot.location!.isNotEmpty)
                    Expanded(
                      child: Text(
                        lot.location!,
                        style: context.texts.bodySmall?.copyWith(color: c.inkDim),
                      ),
                    ),
                ],
              ),

              if (_error != null) ...[
                const SizedBox(height: EtShape.gap),
                EtNotice(text: _error!, icon: Icons.error_outline, tone: 'danger'),
              ],

              const SizedBox(height: EtShape.gap),
              EtCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    EtProgress(
                      percent: taken,
                      label: availabilityLabel(lot),
                      trailing: taken == 0 ? null : 'занято ${(taken * 100).round()} %',
                    ),
                    const SizedBox(height: 14),
                    for (final format in ['half', 'whole'])
                      if (offers[format]!.sellable)
                        EtRow(
                          label: offers[format]!.label,
                          sub: [
                            weightLabel(offers[format]!.weight),
                            if (!offers[format]!.available) 'забронирована',
                          ].where((s) => s.isNotEmpty).join(' · '),
                          value: formatTenge(offers[format]!.meat),
                          valueColor: offers[format]!.available ? null : c.inkFaint,
                        ),
                    if (lot.pricePerKg > 0)
                      EtRow(label: 'Цена за килограмм', value: '${formatTenge(lot.pricePerKg)}/кг'),
                  ],
                ),
              ),

              if (lot.description.isNotEmpty) ...[
                const SizedBox(height: EtShape.gap),
                EtCard(child: Text(lot.description, style: context.texts.bodyMedium)),
              ],

              const SizedBox(height: EtShape.gap),
              EtCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Животное', style: context.texts.titleSmall),
                    const SizedBox(height: 4),
                    if (animal == null)
                      Text(
                        'К лоту не привязано животное. Покупатель не увидит породу и возраст.',
                        style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
                      )
                    else ...[
                      EtRow(label: 'Вид', value: meatLabel[animal.type] ?? '—'),
                      if (animal.breed.isNotEmpty) EtRow(label: 'Порода', value: animal.breed),
                      if (animal.ageCategory != null && animal.ageCategory!.isNotEmpty)
                        EtRow(label: 'Возраст', value: animal.ageCategory!),
                      if (animal.weight > 0)
                        EtRow(label: 'Живой вес', value: weightLabel(animal.weight)),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: EtShape.gap),
              EtNotice(
                text: lot.bookedShares > 0
                    ? 'Лот уже забронирован — менять его нельзя: за долями стоят деньги '
                        'покупателей. Шаги сделки ведутся в заказе.'
                    : 'Пока лот никто не забронировал, его можно вернуть в черновик, '
                        'переписать или удалить.',
                icon: lot.bookedShares > 0 ? Icons.lock_outline : Icons.edit_outlined,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }

  /// Действия — это переходы состояния, и каждое подписано тем, что случится дальше.
  Widget? _actions(Lot lot) {
    final next = switch (lot.status) {
      'draft' => ('Опубликовать', 'open', 'Покупатели увидят тушу в каталоге'),
      'open' when lot.bookedShares == 0 => (
          'Вернуть в черновик',
          'draft',
          'Туша исчезнет из каталога, пока вы её не опубликуете снова'
        ),
      'fully_booked' => ('Отправить', 'in_transit', 'Все доли разобраны'),
      'in_transit' => ('Закрыть лот', 'sold', 'Туша доставлена целиком'),
      _ => null,
    };
    if (next == null) return null;

    return EtBottomBar(
      caption: Text(
        next.$3,
        style: context.texts.bodySmall?.copyWith(color: context.et.inkFaint),
      ),
      child: FilledButton(
        onPressed: _busy ? null : () => _setStatus(next.$2),
        child: Text(_busy ? 'Минуту…' : next.$1),
      ),
    );
  }
}
