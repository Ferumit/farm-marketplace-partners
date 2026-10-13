import 'dart:io';

import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/delivery_step.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';

/// «След» — путь туши от двора до покупателя.
///
/// Переписан на общую дизайн-систему; данные те же, что у кабинета на сайте
/// (deliveries/{lotId}/steps), чтобы отмеченный здесь этап был виден и там.
///
/// Это НЕ шаги заказа. Шаги заказа — обязательные четыре, их ведут в самом заказе, и по ним
/// открываются выплаты. След — рассказ о туше: где она была и как ехала. Он ни на что не влияет,
/// и поэтому здесь ничего не требуется — можно отметить этап, можно приложить фотографию, можно
/// не трогать вовсе.
class TraceabilityScreen extends StatefulWidget {
  const TraceabilityScreen({super.key});

  @override
  State<TraceabilityScreen> createState() => _TraceabilityScreenState();
}

class _TraceabilityScreenState extends State<TraceabilityScreen> {
  final _uploads = Uploads();

  String? _lotId;
  String? _busyStep;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthService>().uid;
    if (uid == null) return const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(title: const Text('След')),
      body: StreamBuilder<List<Lot>>(
        stream: FarmRepo().lots(uid),
        builder: (context, snapshot) {
          final lots = snapshot.data ?? const <Lot>[];
          if (!snapshot.hasData) {
            return const Padding(
              padding: EdgeInsets.all(EtShape.gutter),
              child: EtSkeleton(height: 120),
            );
          }
          if (lots.isEmpty) {
            return const EtEmpty(
              title: 'Следить пока не за чем',
              illustrated: true,
              text: 'След появляется у туши, которую вы выставили. Соберите лот — и здесь можно '
                  'будет отметить, где он побывал.',
              icon: Icons.route_outlined,
            );
          }

          final selected = lots.firstWhere(
            (lot) => lot.id == _lotId,
            orElse: () => lots.first,
          );

          return Column(
            children: [
              _lotPicker(lots, selected),
              Expanded(child: _steps(selected)),
            ],
          );
        },
      ),
    );
  }

  Widget _lotPicker(List<Lot> lots, Lot selected) {
    final c = context.et;
    return SizedBox(
      height: 54,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: EtShape.gutter),
        children: [
          for (final lot in lots)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(lot.name),
                selected: lot.id == selected.id,
                showCheckmark: false,
                onSelected: (_) => setState(() => _lotId = lot.id),
                selectedColor: c.green,
                labelStyle: context.texts.labelLarge?.copyWith(
                  color: lot.id == selected.id ? c.onGreen : c.ink,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _steps(Lot lot) {
    final firestore = context.read<FirestoreService>();

    return StreamBuilder<List<DeliveryStep>>(
      stream: firestore.getDeliverySteps(lot.id),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(EtShape.gutter),
            child: EtSkeleton(height: 140),
          );
        }

        final steps = [...snapshot.data!]..sort((a, b) => a.order.compareTo(b.order));
        if (steps.isEmpty) {
          return EtEmpty(
            title: 'След ещё не начат',
            text: 'Заведите путь этой туши — отметки увидит покупатель на странице заказа.',
            icon: Icons.route_outlined,
            action: FilledButton(
              onPressed: () => firestore.initDeliveryStepsIfEmpty(lot.id),
              child: const Text('Начать след'),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(EtShape.gutter, 0, EtShape.gutter, EtShape.gutter),
          children: [
            const EtNotice(
              text: 'Это рассказ о туше, а не обязательные шаги заказа: на выплаты он не влияет. '
                  'Покупателю приятно видеть, где побывало его мясо.',
              icon: Icons.info_outline,
            ),
            const SizedBox(height: EtShape.gap),
            if (_error != null) ...[
              EtNotice(text: _error!, icon: Icons.error_outline, tone: 'danger'),
              const SizedBox(height: EtShape.gap),
            ],
            for (final step in steps) _stepCard(lot, step, firestore),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  Widget _stepCard(Lot lot, DeliveryStep step, FirestoreService firestore) {
    final c = context.et;
    final done = step.status == 'completed';
    final busy = _busyStep == step.id;

    return Padding(
      padding: const EdgeInsets.only(bottom: EtShape.gap),
      child: EtCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  done ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 20,
                  color: done ? c.green : c.inkFaint,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(step.title, style: context.texts.titleSmall),
                      if (step.subtitle.isNotEmpty)
                        Text(
                          step.subtitle,
                          style: context.texts.bodySmall?.copyWith(color: c.inkDim),
                        ),
                      if (step.completedAt != null)
                        Text(
                          whenText(step.completedAt),
                          style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (step.mediaUrl != null && step.mediaUrl!.isNotEmpty) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(EtShape.radiusSmall),
                child: Image.network(
                  step.mediaUrl!,
                  height: 150,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => const SizedBox.shrink(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : () => _attach(lot, step, firestore),
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    label: Text(step.mediaUrl == null ? 'Снять' : 'Заменить'),
                  ),
                ),
                if (!done) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: busy ? null : () => _complete(step, firestore),
                      child: Text(busy ? '…' : 'Пройден'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _attach(Lot lot, DeliveryStep step, FirestoreService firestore) async {
    final uid = context.read<AuthService>().uid;
    if (uid == null) return;
    final picked = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 88);
    if (picked == null) return;

    setState(() {
      _busyStep = step.id;
      _error = null;
    });
    try {
      final url = await _uploads.media(
        path: Paths.lotImage(uid, 'step_${lot.id}_${step.id}_'
            '${DateTime.now().millisecondsSinceEpoch}.jpg'),
        file: File(picked.path),
      );
      await firestore.saveStepMedia(lot.id, step.id, url);
    } on UploadRefused catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось приложить фотографию.');
    } finally {
      if (mounted) setState(() => _busyStep = null);
    }
  }

  Future<void> _complete(DeliveryStep step, FirestoreService firestore) async {
    setState(() {
      _busyStep = step.id;
      _error = null;
    });
    try {
      await firestore.updateDeliveryStep(
        step.copyWith(status: 'completed', completedAt: DateTime.now()),
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось отметить этап.');
    } finally {
      if (mounted) setState(() => _busyStep = null);
    }
  }
}
