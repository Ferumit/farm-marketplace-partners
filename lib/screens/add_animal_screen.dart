import 'dart:io';

import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import 'animal_screen.dart';

/// Заводим животное.
///
/// The same fields the website's cabinet writes, so a farm that keeps its livestock from a phone
/// and a laptop sees one list: breed, вид, возраст, пол, живой вес, цена за кг, область, фото.
/// Paperwork is attached afterwards - a document belongs to an animal that already exists.
class AddAnimalScreen extends StatefulWidget {
  const AddAnimalScreen({super.key});

  @override
  State<AddAnimalScreen> createState() => _AddAnimalScreenState();
}

class _AddAnimalScreenState extends State<AddAnimalScreen> {
  static const _breeds = {
    'cattle': ['Казахская белоголовая', 'Ангус', 'Герефорд', 'Симментал', 'Аулиекольская'],
    'horse': ['Мугалжарская', 'Кушумская', 'Жабы', 'Костанайская'],
  };

  static const _ages = {
    'cattle': ['бұзау', 'торпақ', 'тайынша', 'ересек'],
    'horse': ['құлын', 'тай', 'құнан', 'байтал'],
  };

  final _farms = FarmRepo();
  final _uploads = Uploads();
  final _breedOther = TextEditingController();
  final _weight = TextEditingController();
  final _price = TextEditingController();

  String _type = 'cattle';
  String? _breed;
  String? _age;
  String _gender = 'male';
  File? _photo;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _breed = _breeds[_type]!.first;
    _age = _ages[_type]!.first;
  }

  @override
  void dispose() {
    _breedOther.dispose();
    _weight.dispose();
    _price.dispose();
    super.dispose();
  }

  void _switchType(String type) {
    setState(() {
      _type = type;
      _breed = _breeds[type]!.first;
      _age = _ages[type]!.first;
    });
  }

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

  Future<void> _save() async {
    final uid = context.read<AuthService>().uid;
    if (uid == null) return;

    final breed = _breed == '__other' ? _breedOther.text.trim() : (_breed ?? '');
    final weight = double.tryParse(_weight.text.replaceAll(',', '.').trim());
    final price = parseTenge(_price.text);

    if (breed.isEmpty) {
      setState(() => _error = 'Укажите породу.');
      return;
    }
    if (weight == null || weight <= 0) {
      setState(() => _error = 'Укажите живой вес в килограммах — например, 380.');
      return;
    }
    if (price == null || price == 0) {
      setState(() => _error = 'Укажите цену за килограмм.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final farm = await _farms.read(uid);
      String? imageUrl;
      if (_photo != null) {
        imageUrl = await _uploads.media(
          path: 'animals/$uid/${DateTime.now().millisecondsSinceEpoch}.jpg',
          file: _photo!,
        );
      }
      final id = await _farms.addAnimal(Animal(
        id: '',
        partnerId: uid,
        type: _type,
        breed: breed,
        ageCategory: _age,
        gender: _gender,
        weight: weight,
        pricePerKg: price,
        imageUrl: imageUrl,
        // Livestock stands where the farm does unless it says otherwise; the website fills the
        // same pair from the farm's region, and its filters read the code.
        region: farm?.city,
        regionCode: farm?.regionCode,
      ));
      if (!mounted) return;
      // Straight to the animal: its paperwork is the next thing to do, and it can only be
      // attached now that the animal exists.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => AnimalScreen(animalId: id)),
      );
    } on UploadRefused catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Не удалось сохранить. Проверьте связь.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final breeds = _breeds[_type]!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Новое животное'),
        actions: const [EtHelpButton(articleId: 'animals')],
      ),
      body: ListView(
        padding: const EdgeInsets.all(EtShape.gutter),
        children: [
          EtCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Вид', style: context.texts.titleSmall),
                const SizedBox(height: 10),
                SegmentedButton<String>(
                  segments: [
                    for (final entry in meatLabel.entries)
                      ButtonSegment(value: entry.key, label: Text(entry.value)),
                  ],
                  selected: {_type},
                  onSelectionChanged: (values) => _switchType(values.first),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _breed,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Порода'),
                  items: [
                    for (final breed in breeds)
                      DropdownMenuItem(value: breed, child: Text(breed)),
                    const DropdownMenuItem(value: '__other', child: Text('Другая порода')),
                  ],
                  onChanged: (value) => setState(() => _breed = value),
                ),
                if (_breed == '__other') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: _breedOther,
                    maxLength: 60,
                    decoration: const InputDecoration(labelText: 'Порода', counterText: ''),
                  ),
                ],
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: _age,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Возраст'),
                  items: [
                    for (final age in _ages[_type]!)
                      DropdownMenuItem(value: age, child: Text(age)),
                  ],
                  onChanged: (value) => setState(() => _age = value),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: _gender,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Пол'),
                  items: const [
                    DropdownMenuItem(value: 'male', child: Text('Самец')),
                    DropdownMenuItem(value: 'female', child: Text('Самка')),
                  ],
                  onChanged: (value) => setState(() => _gender = value ?? 'male'),
                ),
              ],
            ),
          ),
          const SizedBox(height: EtShape.gap),
          EtCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Вес и цена', style: context.texts.titleSmall),
                const SizedBox(height: 4),
                Text(
                  'Живой вес и то, за сколько вы готовы отдать килограмм. Цену туши вы всё равно '
                  'назначаете в лоте — это отправная точка.',
                  style: context.texts.bodySmall?.copyWith(color: c.inkDim),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _weight,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Живой вес, кг'),
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
              ],
            ),
          ),
          const SizedBox(height: EtShape.gap),
          EtCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Фото', style: context.texts.titleSmall),
                const SizedBox(height: 10),
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
          if (_error != null) ...[
            const SizedBox(height: EtShape.gap),
            EtNotice(text: _error!, icon: Icons.error_outline, tone: 'danger'),
          ],
          const SizedBox(height: EtShape.gap),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Сохраняем…' : 'Сохранить и добавить документы'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
