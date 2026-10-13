import 'dart:io';

import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';

/// «Собрать тушу» — как лот появляется на свет.
///
/// Переписан на общую дизайн-систему и на общую арифметику: цену считает та же функция, что
/// покажет её покупателю и что применит сервер при заказе. Раньше экран считал цену доли сам и
/// не записывал цену за килограмм — покупатель видел сумму, но не видел, из чего она.
///
/// Лот создаётся ЧЕРНОВИКОМ: пока хозяйство не нажмёт «Опубликовать» на странице лота, туши в
/// каталоге нет. Это даёт спокойно заполнить всё и посмотреть, что получилось.
class LotConstructorScreen extends StatefulWidget {
  const LotConstructorScreen({super.key});

  @override
  State<LotConstructorScreen> createState() => _LotConstructorScreenState();
}

class _LotConstructorScreenState extends State<LotConstructorScreen> {
  final _farms = FarmRepo();
  final _uploads = Uploads();

  final _name = TextEditingController();
  final _weight = TextEditingController();
  final _price = TextEditingController();
  final _description = TextEditingController();
  final _location = TextEditingController();

  final Set<String> _animals = {};
  File? _photo;
  String _meat = 'cattle';
  bool _halves = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final field in [_name, _weight, _price]) {
      field.addListener(() => setState(() {}));
    }
    _prefillLocation();
  }

  @override
  void dispose() {
    for (final field in [_name, _weight, _price, _description, _location]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _prefillLocation() async {
    final uid = context.read<AuthService>().uid;
    if (uid == null) return;
    final farm = await _farms.read(uid);
    if (mounted && farm?.city != null && _location.text.isEmpty) {
      _location.text = farm!.city!;
    }
  }

  double get _kg => double.tryParse(_weight.text.replaceAll(',', '.').trim()) ?? 0;
  int get _perKg => parseTenge(_price.text) ?? 0;
  int get _shares => _halves ? 2 : 1;

  /// Предварительный расчёт той же функцией, что посчитает цену покупателю.
  Lot get _draft => Lot(
        id: '',
        partnerId: '',
        name: _name.text.trim(),
        description: _description.text.trim(),
        animalIds: _animals.toList(),
        status: 'open',
        totalShares: _shares,
        bookedShares: 0,
        pricePerKg: _perKg,
        totalWeight: _kg,
        pricePerShare: _kg > 0 && _perKg > 0 ? (_perKg * _kg / _shares).round() : 0,
        meatType: _meatType,
        location: _location.text.trim(),
      );

  /// Вид мяса спрашивается прямо, а не выводится из отмеченного животного: лот без животного
  /// уходил в каталог как говядина, даже если это конина.
  String get _meatType => _meat;

  bool get _ready => _name.text.trim().length >= 3 && _kg > 0 && _perKg > 0;

  Future<void> _pickPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Сфотографировать'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Выбрать из галереи'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 88);
    if (picked != null) setState(() => _photo = File(picked.path));
  }

  Future<void> _create() async {
    final uid = context.read<AuthService>().uid;
    if (uid == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      String? imageUrl;
      if (_photo != null) {
        imageUrl = await _uploads.media(
          path: Paths.lotImage(uid, '${DateTime.now().millisecondsSinceEpoch}.jpg'),
          file: _photo!,
        );
      }

      final draft = _draft;
      await _farms.createLot(Lot(
        id: '',
        partnerId: uid,
        name: draft.name,
        description: draft.description,
        animalIds: draft.animalIds,
        // Черновик: в каталоге туша появится после «Опубликовать» на странице лота.
        status: 'draft',
        totalShares: draft.totalShares,
        bookedShares: 0,
        pricePerKg: draft.pricePerKg,
        totalWeight: draft.totalWeight,
        pricePerShare: draft.pricePerShare,
        imageUrl: imageUrl,
        meatType: draft.meatType,
        location: draft.location,
      ));
      if (mounted) Navigator.of(context).pop();
    } on UploadRefused catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(e, st, fatal: false);
      if (mounted) setState(() => _error = 'Не удалось создать лот. Проверьте связь.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthService>().uid;
    final c = context.et;
    final offers = formatsOf(_draft);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Собрать тушу'),
        actions: const [EtHelpButton(articleId: 'lots')],
      ),
      body: ListView(
        padding: const EdgeInsets.all(EtShape.gutter),
        children: [
          const EtNotice(
            text: 'Лот сохранится черновиком. Покупатели увидят его, когда вы нажмёте '
                '«Опубликовать» на странице лота.',
            icon: Icons.edit_outlined,
          ),
          const SizedBox(height: EtShape.gap),

          EtCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Что продаём', style: context.texts.titleSmall),
                const SizedBox(height: 10),
                TextField(
                  controller: _name,
                  maxLength: 80,
                  decoration: const InputDecoration(
                    labelText: 'Название',
                    hintText: 'Казахская белоголовая, торпақ',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _weight,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Вес туши, кг'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _price,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '₸ за кг'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SegmentedButton<String>(
                  segments: [
                    for (final entry in meatLabel.entries)
                      ButtonSegment(value: entry.key, label: Text(entry.value)),
                  ],
                  selected: {_meat},
                  onSelectionChanged: (value) => setState(() => _meat = value.first),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _location,
                  maxLength: 80,
                  decoration: const InputDecoration(
                    labelText: 'Где забирать',
                    hintText: 'Астана',
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
                Text('Как продаём', style: context.texts.titleSmall),
                const SizedBox(height: 4),
                Text(
                  'Половинами тушу разбирают быстрее: покупателю проще взять 65 кг, чем 130.',
                  style: context.texts.bodySmall?.copyWith(color: c.inkDim),
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Половинами')),
                    ButtonSegment(value: false, label: Text('Целиком')),
                  ],
                  selected: {_halves},
                  onSelectionChanged: (value) => setState(() => _halves = value.first),
                ),
                const SizedBox(height: 14),
                if (_kg > 0 && _perKg > 0) ...[
                  if (offers['half']!.sellable)
                    EtRow(
                      label: 'Половина туши',
                      sub: weightLabel(offers['half']!.weight),
                      value: formatTenge(offers['half']!.meat),
                    ),
                  EtRow(
                    label: 'Целая туша',
                    sub: weightLabel(offers['whole']!.weight),
                    value: formatTenge(offers['whole']!.meat),
                    strong: true,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Это цена мяса. Разделку и доставку покупатель добавляет сам — из вашей '
                    'витрины.',
                    style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
                  ),
                ] else
                  Text(
                    'Укажите вес и цену за килограмм — покажу, во что это сложится.',
                    style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
                  ),
              ],
            ),
          ),

          const SizedBox(height: EtShape.gap),
          if (uid != null) _animalPicker(uid),

          const SizedBox(height: EtShape.gap),
          EtCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Фотография', style: context.texts.titleSmall),
                const SizedBox(height: 4),
                Text(
                  'Одна фотография туши или животного. Без неё в каталоге будет только цветная '
                  'полоса с видом мяса.',
                  style: context.texts.bodySmall?.copyWith(color: c.inkDim),
                ),
                const SizedBox(height: 12),
                if (_photo != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(EtShape.radiusSmall),
                    child: Image.file(_photo!, height: 160, width: double.infinity, fit: BoxFit.cover),
                  ),
                  const SizedBox(height: 10),
                ],
                OutlinedButton.icon(
                  onPressed: _pickPhoto,
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  label: Text(_photo == null ? 'Добавить фото' : 'Заменить фото'),
                ),
              ],
            ),
          ),

          const SizedBox(height: EtShape.gap),
          EtCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Описание', style: context.texts.titleSmall),
                const SizedBox(height: 10),
                TextField(
                  controller: _description,
                  maxLines: 4,
                  maxLength: 1000,
                  decoration: const InputDecoration(
                    hintText: 'Откорм, возраст, как хранится — то, о чём спрашивают покупатели.',
                    counterText: '',
                  ),
                ),
              ],
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: EtShape.gap),
            EtNotice(text: _error!, icon: Icons.error_outline, tone: 'danger'),
          ],
          const SizedBox(height: 24),
        ],
      ),
      bottomNavigationBar: EtBottomBar(
        caption: _kg > 0 && _perKg > 0
            ? Row(
                children: [
                  Expanded(
                    child: Text(
                      'Целая туша · ${weightLabel(_kg)}',
                      style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
                    ),
                  ),
                  Text(formatTenge(offers['whole']!.meat), style: context.texts.titleMedium),
                ],
              )
            : null,
        child: FilledButton(
          onPressed: _ready && !_busy ? _create : null,
          child: Text(_busy ? 'Сохраняем…' : 'Сохранить черновик'),
        ),
      ),
    );
  }

  /// Животные из своего скота: из них покупатель узнаёт породу и возраст, а платформа — что
  /// бумаги на эту тушу проверены.
  Widget _animalPicker(String uid) {
    final c = context.et;
    return StreamBuilder<List<Animal>>(
      stream: _farms.animals(uid),
      builder: (context, snapshot) {
        final animals = snapshot.data ?? const <Animal>[];

        return EtCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Животное', style: context.texts.titleSmall),
              const SizedBox(height: 4),
              Text(
                animals.isEmpty
                    ? 'Скота пока нет. Лот можно сохранить и без него, но покупатель не увидит '
                        'породу и возраст, а бумаги не к чему привязать.'
                    : 'Отметьте, из кого собрана туша.',
                style: context.texts.bodySmall?.copyWith(color: c.inkDim),
              ),
              for (final animal in animals)
                CheckboxListTile(
                  value: _animals.contains(animal.id),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _animals.add(animal.id);
                      _meat = animal.type;
                    } else {
                      _animals.remove(animal.id);
                    }
                  }),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    animal.breed.isEmpty ? (meatLabel[animal.type] ?? 'Животное') : animal.breed,
                    style: context.texts.bodyMedium,
                  ),
                  subtitle: Text(
                    [
                      meatLabel[animal.type] ?? '',
                      if (animal.ageCategory != null && animal.ageCategory!.isNotEmpty)
                        animal.ageCategory!,
                      if (animal.weight > 0) weightLabel(animal.weight),
                    ].where((s) => s.isNotEmpty).join(' · '),
                    style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
