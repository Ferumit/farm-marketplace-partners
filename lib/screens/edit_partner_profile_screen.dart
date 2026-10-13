import 'dart:io';

import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';

/// Что хозяйство может изменить о себе само: название, город и фотографию.
///
/// Остальное — статус, рейтинг, число сделок, балансы, значок «Сертификаты» — решает платформа, и
/// отсюда не отправляется вовсе; правила откажут, даже если попробовать. Реквизиты и ИИН живут в
/// «Реквизитах», в приватной записи: профиль читают покупатели.
class EditPartnerProfileScreen extends StatefulWidget {
  const EditPartnerProfileScreen({super.key});

  @override
  State<EditPartnerProfileScreen> createState() => _EditPartnerProfileScreenState();
}

class _EditPartnerProfileScreenState extends State<EditPartnerProfileScreen> {
  final _farms = FarmRepo();
  final _uploads = Uploads();
  final _name = TextEditingController();
  final _city = TextEditingController();

  Partner? _farm;
  File? _avatar;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _city.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final uid = context.read<AuthService>().uid;
    if (uid == null) return;
    final farm = await _farms.read(uid);
    if (!mounted) return;
    setState(() {
      _farm = farm;
      _name.text = farm?.displayName ?? '';
      _city.text = farm?.city ?? '';
      _loading = false;
    });
  }

  Future<void> _pickAvatar() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked != null) setState(() => _avatar = File(picked.path));
  }

  Future<void> _save() async {
    final uid = context.read<AuthService>().uid;
    if (uid == null) return;
    if (_name.text.trim().length < 2) {
      setState(() => _error = 'Название хозяйства — хотя бы два знака.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      String? avatarUrl;
      if (_avatar != null) {
        avatarUrl = await _uploads.media(
          path: Paths.farmMedia(uid, 'avatar_${DateTime.now().millisecondsSinceEpoch}.jpg'),
          file: _avatar!,
        );
      }
      await _farms.saveProfile(
        uid,
        displayName: _name.text.trim(),
        city: _city.text.trim(),
        avatarUrl: avatarUrl,
      );
      if (mounted) Navigator.of(context).pop();
    } on UploadRefused catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось сохранить. Проверьте связь.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.et;

    return Scaffold(
      appBar: AppBar(title: const Text('Профиль хозяйства')),
      body: _loading
          ? const Padding(
              padding: EdgeInsets.all(EtShape.gutter),
              child: EtSkeleton(height: 200),
            )
          : ListView(
              padding: const EdgeInsets.all(EtShape.gutter),
              children: [
                Center(
                  child: Column(
                    children: [
                      _avatarCircle(),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: _pickAvatar,
                        child: Text(_avatar == null ? 'Выбрать фото' : 'Выбрать другое'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: EtShape.gap),
                EtCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Как вас видят покупатели', style: context.texts.titleSmall),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _name,
                        maxLength: 80,
                        decoration: const InputDecoration(
                          labelText: 'Название хозяйства',
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _city,
                        maxLength: 80,
                        decoration: const InputDecoration(
                          labelText: 'Город или область',
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
                      Text('Что меняет платформа', style: context.texts.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                        'Это не редактируется из приложения — и это защита, а не ограничение: '
                        'иначе рейтинг и статус можно было бы себе нарисовать.',
                        style: context.texts.bodySmall?.copyWith(color: c.inkDim),
                      ),
                      const SizedBox(height: 10),
                      EtRow(
                        label: 'Статус',
                        value: farmStatusLabel[_farm?.status ?? ''] ?? 'На проверке',
                      ),
                      EtRow(
                        label: 'Рейтинг',
                        value: (_farm?.rating ?? 0).toStringAsFixed(1),
                      ),
                      EtRow(label: 'Сделок', value: '${_farm?.totalDeals ?? 0}'),
                      EtRow(
                        label: 'Сертификаты',
                        value: (_farm?.certified ?? false) ? 'подтверждены' : 'нет',
                      ),
                      EtRow(label: 'Телефон', value: _farm?.phone ?? ''),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: EtShape.gap),
                  EtNotice(text: _error!, icon: Icons.error_outline, tone: 'danger'),
                ],
                const SizedBox(height: EtShape.gap),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(_busy ? 'Сохраняем…' : 'Сохранить'),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _avatarCircle() {
    final c = context.et;
    final url = _farm?.avatarUrl;
    return Container(
      width: 108,
      height: 108,
      decoration: BoxDecoration(
        color: c.greenTint,
        shape: BoxShape.circle,
        image: _avatar != null
            ? DecorationImage(image: FileImage(_avatar!), fit: BoxFit.cover)
            : (url != null && url.isNotEmpty
                ? DecorationImage(image: NetworkImage(url), fit: BoxFit.cover)
                : null),
      ),
      alignment: Alignment.center,
      child: _avatar == null && (url == null || url.isEmpty)
          ? Text(
              _initials(_name.text),
              style: context.texts.headlineSmall?.copyWith(color: c.green),
            )
          : null,
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return 'ET';
    if (parts.length == 1) return parts.first.characters.take(2).toString().toUpperCase();
    return (parts[0].characters.take(1).toString() + parts[1].characters.take(1).toString())
        .toUpperCase();
  }
}
