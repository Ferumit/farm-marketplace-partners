import 'dart:io';

import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';

/// «Витрина» - leadership's window 2.0: what buyers see of this farm.
///
/// The description, the slaughterhouse video, the paid cutting and the delivery the farm does
/// itself. Prices here are the ones the server will charge: createOrder prices every order from
/// this record, never from what a browser or a phone sends, so what is typed here IS the price.
class StorefrontScreen extends StatefulWidget {
  const StorefrontScreen({super.key});

  @override
  State<StorefrontScreen> createState() => _StorefrontScreenState();
}

class _StorefrontScreenState extends State<StorefrontScreen> {
  static const _maxCutting = 20;
  static const _maxDelivery = 60;

  final _farms = FarmRepo();
  final _uploads = Uploads();
  final _description = TextEditingController();

  Partner? _farm;
  bool _pickup = false;
  List<_CuttingDraft> _cutting = [];
  List<_DeliveryDraft> _delivery = [];
  String? _videoUrl;

  bool _loading = true;
  bool _saving = false;
  double? _videoProgress;
  String? _error;

  String? get _uid => context.read<AuthService>().uid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _description.dispose();
    for (final row in _cutting) {
      row.dispose();
    }
    for (final row in _delivery) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final uid = _uid;
    if (uid == null) return;
    final farm = await _farms.read(uid);
    if (!mounted) return;
    final storefront = farm?.storefront ?? const Storefront();
    setState(() {
      _farm = farm;
      _description.text = storefront.description;
      _pickup = storefront.pickup;
      _videoUrl = storefront.videoUrl;
      _cutting = storefront.cutting.map(_CuttingDraft.of).toList();
      _delivery = storefront.delivery.map(_DeliveryDraft.of).toList();
      _loading = false;
    });
  }

  Storefront? _collect() {
    final cutting = <CuttingOption>[];
    for (final row in _cutting) {
      final name = row.name.text.trim();
      final price = parseTenge(row.price.text);
      if (name.isEmpty && row.price.text.trim().isEmpty) continue;
      if (name.isEmpty) {
        setState(() => _error = 'У платной разделки должно быть название.');
        return null;
      }
      if (price == null) {
        setState(() => _error = 'Укажите цену разделки «$name» — целым числом в тенге.');
        return null;
      }
      final note = row.note.text.trim();
      cutting.add(CuttingOption(
        id: row.id,
        name: name,
        price: price,
        note: note.isEmpty ? null : note,
      ));
    }

    final delivery = <DeliveryTariff>[];
    for (final row in _delivery) {
      final city = row.city.text.trim();
      final price = parseTenge(row.price.text);
      if (city.isEmpty && row.price.text.trim().isEmpty) continue;
      if (city.isEmpty) {
        setState(() => _error = 'У строки доставки должен быть город.');
        return null;
      }
      if (price == null) {
        setState(() => _error = 'Укажите цену доставки в город «$city».');
        return null;
      }
      delivery.add(DeliveryTariff(id: row.id, city: city, price: price));
    }

    if (delivery.isEmpty && !_pickup) {
      setState(() => _error = 'Покупателю нужен хотя бы один способ получения: '
          'самовывоз из хаба или доставка в город.');
      return null;
    }

    return Storefront(
      description: _description.text.trim(),
      videoUrl: _videoUrl,
      posterUrl: _farm?.storefront.posterUrl,
      pickup: _pickup,
      cutting: cutting,
      delivery: delivery,
    );
  }

  Future<void> _save() async {
    final uid = _uid;
    if (uid == null) return;
    setState(() => _error = null);
    final storefront = _collect();
    if (storefront == null) return;

    setState(() => _saving = true);
    try {
      await _farms.saveStorefront(uid, storefront);
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Витрина сохранена — покупатели видят её сразу.')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Не удалось сохранить. Проверьте связь и попробуйте ещё раз.';
      });
    }
  }

  /// The slaughterhouse video saves itself on top of what is stored: it is a long upload, and
  /// losing it because the rest of the form was mid-edit would be its own kind of cruel.
  Future<void> _pickVideo() async {
    final uid = _uid;
    if (uid == null) return;
    final picked = await ImagePicker().pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(minutes: 3),
    );
    if (picked == null) return;

    setState(() {
      _videoProgress = 0;
      _error = null;
    });
    try {
      final url = await _uploads.media(
        path: Paths.farmMedia(uid, 'video_${DateTime.now().millisecondsSinceEpoch}.mp4'),
        file: File(picked.path),
        onProgress: (value) {
          if (mounted) setState(() => _videoProgress = value);
        },
      );
      final stored = (await _farms.read(uid))?.storefront ?? const Storefront();
      await _farms.saveStorefront(
        uid,
        Storefront(
          description: stored.description,
          videoUrl: url,
          posterUrl: stored.posterUrl,
          pickup: stored.pickup,
          cutting: stored.cutting,
          delivery: stored.delivery,
        ),
      );
      if (!mounted) return;
      setState(() {
        _videoUrl = url;
        _videoProgress = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Видео загружено.')),
      );
    } on UploadRefused catch (e) {
      if (mounted) {
        setState(() {
          _videoProgress = null;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _videoProgress = null;
          _error = 'Видео не загрузилось. Проверьте связь.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Витрина'),
        actions: const [EtHelpButton(articleId: 'storefront')],
      ),
      body: _loading
          ? const Padding(
              padding: EdgeInsets.all(EtShape.gutter),
              child: EtSkeleton(height: 220),
            )
          : ListView(
              padding: const EdgeInsets.all(EtShape.gutter),
              children: [
                const EtNotice(
                  text: 'Это то, что покупатель читает о хозяйстве перед заказом. Цены разделки '
                      'и доставки отсюда — по ним считает заказ сервер.',
                  icon: Icons.storefront_outlined,
                ),
                const SizedBox(height: EtShape.gap),
                _about(),
                const SizedBox(height: EtShape.gap),
                _video(),
                const SizedBox(height: EtShape.gap),
                _cuttingCard(),
                const SizedBox(height: EtShape.gap),
                _deliveryCard(),
                if (_error != null) ...[
                  const SizedBox(height: EtShape.gap),
                  EtNotice(text: _error!, icon: Icons.error_outline, tone: 'danger'),
                ],
                const SizedBox(height: EtShape.gap),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Сохраняем…' : 'Сохранить витрину'),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _about() => EtCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('О хозяйстве', style: context.texts.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Чем кормите, сколько держите, как забиваете и храните — то, о чём покупатель '
              'всё равно спросит в переписке.',
              style: context.texts.bodySmall?.copyWith(color: context.et.inkDim),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              maxLines: 6,
              maxLength: 3000,
              decoration: const InputDecoration(
                hintText: 'Откорм на пастбищах, 18–24 месяца. Свой убойный цех и камера охлаждения.',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      );

  Widget _video() {
    final c = context.et;
    final uploading = _videoProgress != null;
    return EtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Видео убойного цеха', style: context.texts.titleSmall)),
              if (_videoUrl != null && !uploading)
                const EtStatusChip(text: 'Загружено', tone: 'active'),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'До 3 минут. Показывается на странице хозяйства — это самый быстрый способ снять '
            'вопросы о том, как у вас всё устроено.',
            style: context.texts.bodySmall?.copyWith(color: c.inkDim),
          ),
          const SizedBox(height: 12),
          if (uploading) ...[
            EtProgress(
              percent: _videoProgress!,
              label: 'Загружаем видео',
              trailing: '${(_videoProgress! * 100).round()} %',
            ),
          ] else
            OutlinedButton.icon(
              onPressed: _pickVideo,
              icon: const Icon(Icons.videocam_outlined, size: 18),
              label: Text(_videoUrl == null ? 'Загрузить видео' : 'Заменить видео'),
            ),
        ],
      ),
    );
  }

  Widget _cuttingCard() {
    final c = context.et;
    return EtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Разделка', style: context.texts.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Стандартная разделка входит в цену мяса. Здесь — то, за что вы берёте отдельно: '
            'мүшелеу, казы, фасовка.',
            style: context.texts.bodySmall?.copyWith(color: c.inkDim),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _cutting.length; i++) _cuttingRow(i),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _cutting.length >= _maxCutting
                ? null
                : () => setState(() => _cutting.add(_CuttingDraft.empty())),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Платная разделка'),
          ),
        ],
      ),
    );
  }

  Widget _cuttingRow(int index) {
    final row = _cutting[index];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: row.name,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Название', counterText: ''),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: row.price,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '₸ за полтуши'),
                ),
              ),
              IconButton(
                onPressed: () => setState(() => _cutting.removeAt(index).dispose()),
                icon: Icon(Icons.close, color: context.et.inkFaint),
                tooltip: 'Убрать',
              ),
            ],
          ),
          TextField(
            controller: row.note,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Что входит (необязательно)',
              counterText: '',
            ),
          ),
        ],
      ),
    );
  }

  Widget _deliveryCard() {
    final c = context.et;
    return EtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Доставка', style: context.texts.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Города, куда везёте сами, и цена за доставку. Без самовывоза и без городов '
            'покупателю некуда забрать заказ.',
            style: context.texts.bodySmall?.copyWith(color: c.inkDim),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            value: _pickup,
            onChanged: (value) => setState(() => _pickup = value),
            contentPadding: EdgeInsets.zero,
            title: const Text('Самовывоз из хаба — бесплатно'),
            subtitle: Text(
              'Адрес хаба вы сообщаете покупателю, когда принимаете заказ',
              style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
            ),
          ),
          for (var i = 0; i < _delivery.length; i++) _deliveryRow(i),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _delivery.length >= _maxDelivery
                ? null
                : () => setState(() => _delivery.add(_DeliveryDraft.empty())),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Город доставки'),
          ),
        ],
      ),
    );
  }

  Widget _deliveryRow(int index) {
    final row = _delivery[index];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: row.city,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Город', counterText: ''),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: TextField(
              controller: row.price,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '₸'),
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _delivery.removeAt(index).dispose()),
            icon: Icon(Icons.close, color: context.et.inkFaint),
            tooltip: 'Убрать',
          ),
        ],
      ),
    );
  }
}

/// A row being edited. Ids are kept from what was stored: an order that already names a cutting
/// option must keep naming the same one.
class _CuttingDraft {
  _CuttingDraft({required this.id, String? name, String? price, String? note})
      : name = TextEditingController(text: name ?? ''),
        price = TextEditingController(text: price ?? ''),
        note = TextEditingController(text: note ?? '');

  factory _CuttingDraft.of(CuttingOption option) => _CuttingDraft(
        id: option.id,
        name: option.name,
        price: option.price == 0 ? '' : option.price.toString(),
        note: option.note,
      );

  factory _CuttingDraft.empty() => _CuttingDraft(id: newOptionId());

  final String id;
  final TextEditingController name;
  final TextEditingController price;
  final TextEditingController note;

  void dispose() {
    name.dispose();
    price.dispose();
    note.dispose();
  }
}

class _DeliveryDraft {
  _DeliveryDraft({required this.id, String? city, String? price})
      : city = TextEditingController(text: city ?? ''),
        price = TextEditingController(text: price ?? '');

  factory _DeliveryDraft.of(DeliveryTariff tariff) => _DeliveryDraft(
        id: tariff.id,
        city: tariff.city,
        price: tariff.price == 0 ? '' : tariff.price.toString(),
      );

  factory _DeliveryDraft.empty() => _DeliveryDraft(id: newOptionId());

  final String id;
  final TextEditingController city;
  final TextEditingController price;

  void dispose() {
    city.dispose();
    price.dispose();
  }
}
