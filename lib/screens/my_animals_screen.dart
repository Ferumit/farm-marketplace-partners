import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import 'add_animal_screen.dart';
import 'animal_screen.dart';

/// «Скот» - the farm's livestock, and the state of the paperwork on each head.
///
/// The paperwork is the point of the list: a buyer sees whether an animal's papers were checked,
/// and a farm whose certificates are missing will not be confirmed. So every row carries the
/// worst verdict across its documents, the same summary the website shows.
class MyAnimalsScreen extends StatelessWidget {
  const MyAnimalsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthService>().uid;
    if (uid == null) return const SizedBox.shrink();
    final farms = FarmRepo();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Скот'),
        actions: [
          IconButton(
            tooltip: 'Добавить животное',
            icon: const Icon(Icons.add),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AddAnimalScreen()),
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<Animal>>(
        stream: farms.animals(uid),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const EtEmpty(
              title: 'Не удалось загрузить скот',
              text: 'Проверьте связь.',
              icon: Icons.cloud_off,
            );
          }
          if (!snapshot.hasData) {
            return const Padding(
              padding: EdgeInsets.all(EtShape.gutter),
              child: Column(
                children: [
                  EtSkeleton(height: 96),
                  SizedBox(height: EtShape.gap),
                  EtSkeleton(height: 96),
                ],
              ),
            );
          }

          final animals = snapshot.data!;
          if (animals.isEmpty) {
            return EtEmpty(
              title: 'Скота пока нет',
              illustrated: true,
              text: 'Заведите животных — из них собираются лоты, а покупатель видит, '
                  'проверены ли на них бумаги.',
              icon: Icons.pets_outlined,
              action: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AddAnimalScreen()),
                ),
                child: const Text('Добавить животное'),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(EtShape.gutter),
            children: [
              Text(
                '${animals.length} ${pluralRu(animals.length, 'голова', 'головы', 'голов')}',
                style: context.texts.bodySmall?.copyWith(color: context.et.inkDim),
              ),
              const SizedBox(height: 10),
              for (var i = 0; i < animals.length; i++)
                EtReveal(index: i, child: _AnimalCard(animal: animals[i], farms: farms)),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class _AnimalCard extends StatelessWidget {
  const _AnimalCard({required this.animal, required this.farms});

  final Animal animal;
  final FarmRepo farms;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final details = [
      meatLabel[animal.type] ?? '',
      if (animal.ageCategory != null && animal.ageCategory!.isNotEmpty) animal.ageCategory!,
      if (animal.weight > 0) weightLabel(animal.weight),
      if (animal.pricePerKg > 0) '${formatTenge(animal.pricePerKg)}/кг',
      if (animal.region != null && animal.region!.isNotEmpty) animal.region!,
    ].where((s) => s.isNotEmpty).join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: EtShape.gap),
      child: EtCard(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AnimalScreen(animalId: animal.id)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    animal.breed.isEmpty ? (meatLabel[animal.type] ?? 'Животное') : animal.breed,
                    style: context.texts.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(details, style: context.texts.bodySmall?.copyWith(color: c.inkDim)),
                  const SizedBox(height: 10),
                  StreamBuilder<List<FarmDocument>>(
                    stream: farms.animalDocuments(animal.id),
                    builder: (context, snapshot) {
                      final summary = documentsSummary(snapshot.data ?? const []);
                      return EtStatusChip(text: summary.label, tone: summary.tone);
                    },
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: c.inkFaint),
          ],
        ),
      ),
    );
  }
}
