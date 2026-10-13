import 'dart:io';

import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/auth_service.dart';

/// One head of livestock: what it is, and the paperwork on it.
///
/// A farm files a veterinary certificate as PENDING and cannot approve it - the rules refuse a
/// document that arrives with a verdict, and staff write the verdict through reviewDocument. The
/// farm can withdraw a scan nobody has looked at yet; after that it stays as the record.
class AnimalScreen extends StatefulWidget {
  const AnimalScreen({super.key, required this.animalId});

  final String animalId;

  @override
  State<AnimalScreen> createState() => _AnimalScreenState();
}

class _AnimalScreenState extends State<AnimalScreen> {
  static const _kinds = [
    (id: 'vet_certificate', label: 'Ветеринарная справка (форма №1)'),
    (id: 'vet_passport', label: 'Ветеринарный паспорт'),
    (id: 'other', label: 'Другой документ'),
  ];

  final _farms = FarmRepo();
  final _uploads = Uploads();

  Animal? _animal;
  bool _loading = true;
  double? _progress;
  String? _error;

  String? get _uid => context.read<AuthService>().uid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final animal = await _farms.animal(widget.animalId);
    if (!mounted) return;
    setState(() {
      _animal = animal;
      _loading = false;
    });
  }

  /// Which paper is being filed, then the photograph of it. Two short questions beat a screen of
  /// buttons - and the farm is standing in a yard with one hand free.
  Future<void> _addDocument() async {
    final kind = await showModalBottomSheet<({String id, String label})>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(EtShape.gutter, 16, EtShape.gutter, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Что снимаем?'),
              ),
            ),
            for (final kind in _kinds)
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(kind.label),
                onTap: () => Navigator.pop(context, kind),
              ),
          ],
        ),
      ),
    );
    if (kind == null) return;
    await _file(kind.id, kind.label);
  }

  Future<void> _file(String kind, String label) async {
    final uid = _uid;
    if (uid == null) return;
    final picked = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 88);
    if (picked == null) return;

    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final ref = _farms.newAnimalDocumentRef(widget.animalId);
      final file = File(picked.path);
      final path = Paths.animalDocument(uid, widget.animalId, ref.id, 'jpg');
      final url = await _uploads.documentFile(
        path: path,
        file: file,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      await _farms.fileDocument(
        ref: ref,
        kind: kind,
        label: label,
        fileUrl: url,
        storagePath: path,
        contentType: Uploads.contentTypeOf(picked.path),
        fileName: picked.name,
        size: await file.length(),
        partnerId: uid,
        animalId: widget.animalId,
      );
      if (!mounted) return;
      setState(() => _progress = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Документ отправлен на проверку.')),
      );
    } on UploadRefused catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = 'Не удалось отправить документ. Проверьте связь.';
        });
      }
    }
  }

  Future<void> _delete() async {
    final animal = _animal;
    if (animal == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить животное?'),
        content: const Text('Оно пропадёт из списка. Лоты, в которых оно уже стоит, '
            'останутся как есть.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Назад')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _farms.deleteAnimal(animal.id);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось удалить. Проверьте связь.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final animal = _animal;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Животное'),
        actions: [
          if (animal != null)
            IconButton(
              tooltip: 'Удалить',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: _loading
          ? const Padding(
              padding: EdgeInsets.all(EtShape.gutter),
              child: EtSkeleton(height: 200),
            )
          : animal == null
              ? const EtEmpty(
                  title: 'Животное не найдено',
                  text: 'Возможно, его уже удалили.',
                  icon: Icons.search_off,
                )
              : _body(animal),
    );
  }

  Widget _body(Animal animal) {
    final c = context.et;
    return ListView(
      padding: const EdgeInsets.all(EtShape.gutter),
      children: [
        if (animal.imageUrl != null && animal.imageUrl!.isNotEmpty) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(EtShape.radiusCard),
            child: Image.network(
              animal.imageUrl!,
              height: 200,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: EtShape.gap),
        ],
        EtCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                animal.breed.isEmpty ? (meatLabel[animal.type] ?? 'Животное') : animal.breed,
                style: context.texts.titleMedium,
              ),
              const SizedBox(height: 8),
              EtRow(label: 'Вид', value: meatLabel[animal.type] ?? '—'),
              if (animal.ageCategory != null && animal.ageCategory!.isNotEmpty)
                EtRow(label: 'Возраст', value: animal.ageCategory!),
              if (animal.gender != null && animal.gender!.isNotEmpty)
                EtRow(
                  label: 'Пол',
                  value: animal.gender == 'female' ? 'самка' : 'самец',
                ),
              if (animal.weight > 0) EtRow(label: 'Живой вес', value: weightLabel(animal.weight)),
              if (animal.pricePerKg > 0)
                EtRow(label: 'Цена за кг', value: '${formatTenge(animal.pricePerKg)}/кг'),
              if (animal.region != null && animal.region!.isNotEmpty)
                EtRow(label: 'Где стоит', value: animal.region!),
            ],
          ),
        ),
        const SizedBox(height: EtShape.gap),
        StreamBuilder<List<FarmDocument>>(
          stream: _farms.animalDocuments(animal.id),
          builder: (context, snapshot) {
            final documents = snapshot.data ?? const <FarmDocument>[];
            final summary = documentsSummary(documents);
            return EtCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('Документы', style: context.texts.titleSmall)),
                      EtStatusChip(text: summary.label, tone: summary.tone),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Покупатель видит, проверены ли бумаги на животное. Проверяет их '
                    'администратор — подтвердить самостоятельно нельзя.',
                    style: context.texts.bodySmall?.copyWith(color: c.inkDim),
                  ),
                  for (final document in documents) ...[
                    const SizedBox(height: 12),
                    _documentRow(document),
                  ],
                  const SizedBox(height: 14),
                  if (_progress != null)
                    EtProgress(
                      percent: _progress!,
                      label: 'Отправляем документ',
                      trailing: '${(_progress! * 100).round()} %',
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: _addDocument,
                      icon: const Icon(Icons.photo_camera_outlined, size: 18),
                      label: const Text('Добавить документ'),
                    ),
                ],
              ),
            );
          },
        ),
        if (_error != null) ...[
          const SizedBox(height: EtShape.gap),
          EtNotice(text: _error!, icon: Icons.error_outline, tone: 'danger'),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _documentRow(FarmDocument document) {
    final c = context.et;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(EtShape.radiusSmall),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(document.label, style: context.texts.bodyMedium)),
              EtStatusChip(
                text: docStatusLabel[document.status] ?? document.status,
                tone: docStatusTone[document.status] ?? 'neutral',
              ),
            ],
          ),
          if (document.reviewNote != null && document.reviewNote!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Администратор: ${document.reviewNote}',
                style: context.texts.bodySmall?.copyWith(color: c.danger),
              ),
            ),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(document.fileUrl),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Открыть'),
              ),
              const Spacer(),
              if (document.status == 'pending')
                TextButton(
                  onPressed: () async {
                    try {
                      await _farms.withdrawDocument(
                        _farms.animalDocumentRef(widget.animalId, document.id),
                      );
                    } catch (_) {
                      if (mounted) setState(() => _error = 'Не удалось убрать документ.');
                    }
                  },
                  child: const Text('Убрать'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
