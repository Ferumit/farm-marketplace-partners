import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import 'lot_constructor_screen.dart';
import 'lot_detail_screen.dart';

/// «Лоты» — туши, которые хозяйство выставило на продажу.
///
/// Переписан на общую дизайн-систему: раньше это был единственный экран кабинета, говоривший
/// капслоком, показывавший штрихкод с «ID: LOT4» и вес с десятичной долей — и при этом НЕ
/// показывавший цену, ради которой лот и заводят.
///
/// Карточка отвечает на три вопроса в том порядке, в каком их задают: что это за туша, сколько
/// её уже забронировали и сколько она стоит.
class MyLotsScreen extends StatefulWidget {
  const MyLotsScreen({super.key});

  @override
  State<MyLotsScreen> createState() => _MyLotsScreenState();
}

class _MyLotsScreenState extends State<MyLotsScreen> {
  static const _filters = [
    (null, 'Все'),
    ('draft', 'Черновики'),
    ('open', 'В продаже'),
    ('fully_booked', 'Забронированы'),
    ('sold', 'Проданы'),
  ];

  String? _status;

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthService>().uid;
    if (uid == null) return const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Лоты'),
        actions: [
          IconButton(
            tooltip: 'Собрать тушу',
            icon: const Icon(Icons.add),
            onPressed: _newLot,
          ),
        ],
      ),
      body: StreamBuilder<List<Lot>>(
        stream: FarmRepo().lots(uid),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const EtEmpty(
              title: 'Не удалось загрузить лоты',
              text: 'Проверьте связь.',
              icon: Icons.cloud_off,
            );
          }
          if (!snapshot.hasData) {
            return const Padding(
              padding: EdgeInsets.all(EtShape.gutter),
              child: Column(
                children: [
                  EtSkeleton(height: 150),
                  SizedBox(height: EtShape.gap),
                  EtSkeleton(height: 150),
                ],
              ),
            );
          }

          final all = snapshot.data!;
          final shown = _status == null
              ? all
              : all.where((lot) => lot.status == _status).toList();

          return Column(
            children: [
              _filterRow(all),
              Expanded(
                child: shown.isEmpty
                    ? EtEmpty(
                        title: all.isEmpty ? 'Лотов пока нет' : 'Здесь пусто',
                        illustrated: all.isEmpty,
                        text: all.isEmpty
                            ? 'Соберите тушу из своего скота и выставьте её — покупатели увидят '
                                'её в каталоге.'
                            : 'В этом состоянии лотов нет. Посмотрите другие.',
                        icon: Icons.inventory_2_outlined,
                        action: all.isEmpty
                            ? FilledButton(
                                onPressed: _newLot,
                                child: const Text('Собрать тушу'),
                              )
                            : null,
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(
                          EtShape.gutter,
                          0,
                          EtShape.gutter,
                          EtShape.gutter,
                        ),
                        children: [
                          for (var i = 0; i < shown.length; i++)
                            EtReveal(index: i, child: _LotCard(lot: shown[i])),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _filterRow(List<Lot> all) {
    final c = context.et;
    return SizedBox(
      height: 54,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: EtShape.gutter),
        children: [
          for (final filter in _filters)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(
                  filter.$1 == null
                      ? filter.$2
                      : '${filter.$2} · ${all.where((l) => l.status == filter.$1).length}',
                ),
                selected: _status == filter.$1,
                showCheckmark: false,
                onSelected: (_) => setState(() => _status = filter.$1),
                selectedColor: c.green,
                labelStyle: context.texts.labelLarge?.copyWith(
                  color: _status == filter.$1 ? c.onGreen : c.ink,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _newLot() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LotConstructorScreen()),
    );
  }
}

class _LotCard extends StatelessWidget {
  const _LotCard({required this.lot});

  final Lot lot;

  static const _status = {
    'draft': ('Черновик', 'off'),
    'open': ('В продаже', 'active'),
    'fully_booked': ('Забронирована', 'waiting'),
    'in_transit': ('В пути', 'waiting'),
    'sold': ('Продана', 'off'),
  };

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final taken = lot.totalShares == 0 ? 0.0 : lot.bookedShares / lot.totalShares;
    final state = _status[lot.status] ?? ('Черновик', 'off');
    final offers = formatsOf(lot);

    return Padding(
      padding: const EdgeInsets.only(bottom: EtShape.gap),
      child: EtCard(
        padding: EdgeInsets.zero,
        onTap: () => _open(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            EtHero(
              label: meatLabel[lot.meatType ?? 'cattle'] ?? 'Мясо',
              meatType: lot.meatType ?? 'cattle',
              imageUrl: lot.imageUrl,
              height: 72,
              note: lot.totalWeight > 0 ? weightLabel(lot.totalWeight) : null,
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(lot.name, style: context.texts.titleMedium),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: EtStatusChip(text: state.$1, tone: state.$2),
                  ),
                  const SizedBox(height: 12),
                  EtProgress(
                    percent: taken,
                    label: availabilityLabel(lot),
                    trailing: taken == 0 ? null : 'занято ${(taken * 100).round()} %',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              offers['half']!.sellable ? 'Половина туши' : 'Целая туша',
                              style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
                            ),
                            Text(
                              formatTenge(
                                offers['half']!.sellable
                                    ? offers['half']!.meat
                                    : offers['whole']!.meat,
                              ),
                              style: context.texts.titleLarge?.copyWith(fontSize: 22),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.arrow_forward, color: c.green),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LotDetailScreen(lotId: lot.id)),
    );
  }
}
