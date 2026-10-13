import 'dart:io';

import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

/// One order, worked from the phone - leadership's window 2.2.
///
/// Four steps, each opening the next: the live animal, the ready meat with its documents and the
/// control weighing, the dispatch, the handover. The camera opens straight into the step, because
/// this screen is used in a yard and in a cold room, not at a desk. Every move goes through
/// updateOrderStatus - the app cannot write an order, and should not be able to.
class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.orderId});

  final String orderId;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  final _orders = OrdersRepo();
  final _api = EtApi();

  bool _busy = false;
  String? _error;
  bool _autoCompleteTried = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on EtApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on UploadRefused catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Не получилось. Проверьте связь и попробуйте ещё раз.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A deal whose three hours ran out while nobody was looking closes itself when the farm opens
  /// it. The scheduled sweep does the same every quarter of an hour; this is what keeps the
  /// screen from showing a state that is no longer true.
  void _closeIfOverdue(FarmOrder order) {
    if (_autoCompleteTried || !isOverdue(order)) return;
    _autoCompleteTried = true;
    _api.autoCompleteOrder(order.id).catchError((_) => '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Заказ'),
        actions: const [EtHelpButton(articleId: 'orders')],
      ),
      body: StreamBuilder<FarmOrder?>(
        stream: _orders.watch(widget.orderId),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const EtEmpty(
              title: 'Заказ недоступен',
              text: 'Он есть только у своих сторон. Проверьте связь.',
              icon: Icons.lock_outline,
            );
          }
          final order = snapshot.data;
          if (order == null) {
            return const Padding(
              padding: EdgeInsets.all(EtShape.gutter),
              child: EtSkeleton(height: 220),
            );
          }
          _closeIfOverdue(order);

          return ListView(
            padding: const EdgeInsets.all(EtShape.gutter),
            children: [
              _header(order),
              const SizedBox(height: EtShape.gap),
              _contacts(order),
              if (order.isJoint) ...[
                const SizedBox(height: EtShape.gap),
                _group(order),
              ],
              const SizedBox(height: EtShape.gap),
              if (stageOf(order.status) == 'disputed') ...[
                const EtNotice(
                  text: 'Покупатель открыл спор. Последняя часть выплаты удержана, пока платформа '
                      'не примет решение — администратор свяжется с вами.',
                  icon: Icons.gavel_outlined,
                  tone: 'danger',
                ),
                const SizedBox(height: EtShape.gap),
              ],
              _acceptPanel(order),
              const SizedBox(height: EtShape.gap),
              _identifyPanel(order),
              const SizedBox(height: EtShape.gap),
              _meatPanel(order),
              const SizedBox(height: EtShape.gap),
              _shipPanel(order),
              const SizedBox(height: EtShape.gap),
              _handoverPanel(order),
              const SizedBox(height: EtShape.gap),
              _money(order),
              if (_error != null) ...[
                const SizedBox(height: EtShape.gap),
                EtNotice(text: _error!, icon: Icons.error_outline, tone: 'danger'),
              ],
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  // ---- head -------------------------------------------------------------------------------

  Widget _header(FarmOrder order) {
    final c = context.et;
    return EtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The title gets the whole width: a carcass name is long, and squeezed next to a chip
          // it broke mid-word ("Казахска я белогол овая").
          Text(order.lotTitle.isEmpty ? 'Заказ' : order.lotTitle,
              style: context.texts.headlineSmall),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: EtStatusChip(
              text: statusTextForFarm(order),
              tone: statusTone(order),
              icon: etStageIcon(order.status),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            orderSummary(
              format: order.format,
              estimatedWeightKg: order.estimatedWeightKg,
              shares: order.shares,
            ),
            style: context.texts.bodyMedium?.copyWith(color: c.inkDim),
          ),
          const SizedBox(height: 4),
          Text(formatTenge(order.total), style: context.texts.headlineSmall),
        ],
      ),
    );
  }

  Widget _contacts(FarmOrder order) {
    final phone = order.contactPhone.isNotEmpty ? order.contactPhone : (order.buyerPhone ?? '');
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    final date = order.deliveryDate == null
        ? 'не указана'
        : '${order.deliveryDate!.split('-').reversed.join('.')}'
            '${order.deliverySlot != null && order.deliverySlot != 'any' ? ', ${slotLabel[order.deliverySlot]?.split(',').first.toLowerCase()}' : ''}';

    return EtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person_outline, size: 18, color: context.et.green),
              const SizedBox(width: 8),
              Text('Покупатель и доставка', style: context.texts.titleSmall),
            ],
          ),
          const SizedBox(height: 6),
          EtRow(label: 'Телефон', value: phone.isEmpty ? '—' : phone),
          EtRow(
            label: 'Доставка',
            value: order.delivery.isPickup
                ? 'самовывоз'
                : (order.delivery.city ?? 'по договорённости'),
          ),
          if (!order.delivery.isPickup)
            EtRow(
              label: 'Адрес',
              value: order.deliveryAddress.isEmpty ? '—' : order.deliveryAddress,
            ),
          EtRow(label: 'Желаемая дата', value: date),
          EtRow(label: 'Разделка', value: order.cutting?.name ?? 'стандартная'),
          if (digits.length >= 10) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => launchUrl(Uri.parse('tel:+$digits')),
                    icon: const Icon(Icons.call_outlined, size: 18),
                    label: const Text('Позвонить'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse('https://wa.me/$digits'),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.chat_outlined, size: 18),
                    label: const Text('WhatsApp'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// A joint purchase is one order with 2-5 people behind it. The farm deals with the organiser,
  /// whose phone is above - the rest are here so nobody is a surprise at the handover.
  Widget _group(FarmOrder order) {
    final group = order.group!;
    return EtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.group_outlined, size: 18, color: context.et.green),
              const SizedBox(width: 8),
              Text('Совместная покупка', style: context.texts.titleSmall),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${group.size} ${pluralRu(group.size, 'участник', 'участника', 'участников')} делят эту тушу. '
            'Заказ ведёт ${group.members.isEmpty ? 'организатор' : group.members.first.name}.',
            style: context.texts.bodySmall?.copyWith(color: context.et.inkDim),
          ),
          const SizedBox(height: 6),
          for (final member in group.members)
            EtRow(label: member.name, value: formatTenge(member.amount)),
        ],
      ),
    );
  }

  // ---- the four steps ----------------------------------------------------------------------

  Widget _acceptPanel(FarmOrder order) {
    final stage = stageOf(order.status);
    if (stage == 'cancelled') {
      return _panel(
        state: _PanelState.done,
        title: 'Заказ отменён',
        subtitle: order.cancelledBy == 'buyer'
            ? 'Покупатель отменил заказ, туша вернулась в продажу.'
            : 'Заказ отменён, туша вернулась в продажу.',
      );
    }
    if (stage != 'created') {
      return _panel(
        state: _PanelState.done,
        title: 'Заказ принят',
        when: order.acceptedAt,
      );
    }
    return _panel(
      state: _PanelState.current,
      title: 'Примите заказ',
      subtitle: 'После принятия открывается аванс 50 % и вы проходите четыре шага до передачи.',
      action: FilledButton(
        onPressed: _busy ? null : () => _run(() => _api.acceptOrder(order.id)),
        child: const Text('Принять заказ'),
      ),
    );
  }

  Widget _identifyPanel(FarmOrder order) {
    final stage = stageOf(order.status);
    final step = order.steps['identify'];
    const title = 'Шаг 1. Живое животное';

    if (step != null) {
      return _panel(
        state: _PanelState.done,
        title: title,
        when: step.at,
        body: EtMediaStrip(items: _media(step.files)),
      );
    }
    if (isFinished(order)) {
      return _panel(state: _PanelState.locked, title: title, subtitle: 'Заказ закрыт — шаг уже не отметить.');
    }
    if (stage == 'cancelled' || !reached(order, 'accepted')) {
      return _panel(state: _PanelState.locked, title: title, subtitle: 'Сначала примите заказ.');
    }
    return _panel(
      state: _PanelState.current,
      title: title,
      subtitle: 'Снимите животное, которое пойдёт на этот заказ. Хотя бы одно фото или видео — '
          'покупатель увидит их в заказе.',
      action: _StepUploader(
        key: ValueKey('identify-${order.id}'),
        partnerId: order.partnerId,
        orderId: order.id,
        allowVideo: true,
        buttonLabel: 'Готово — шаг 1 пройден',
        emptyHint: 'Нужно хотя бы одно фото или видео.',
        busy: _busy,
        onSubmit: (files, _) => _run(() => _api.identifyAnimal(order.id, files)),
      ),
    );
  }

  Widget _meatPanel(FarmOrder order) {
    final stage = stageOf(order.status);
    final step = order.steps['meat'];
    const title = 'Шаг 2. Готовое мясо и взвешивание';

    if (step != null) {
      final weighing = order.weighing;
      return _panel(
        state: _PanelState.done,
        title: title,
        when: step.at,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            EtMediaStrip(items: _media(step.files)),
            if (weighing != null) ...[
              const SizedBox(height: 10),
              EtRow(
                label: 'Контрольный вес',
                sub: weighing.difference > 0
                    ? 'доплата покупателя ${formatTenge(weighing.difference)}'
                    : weighing.difference < 0
                        ? 'возврат покупателю ${formatTenge(-weighing.difference)}'
                        : 'без перерасчёта',
                value: '${kgText(weighing.weightKg)} кг',
                strong: true,
              ),
            ],
            if (step.documents.isNotEmpty || step.certificates.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Документы: ${[
                  ...step.certificates.map((c) => c.label),
                  ...step.documents.map((d) => d.name.isEmpty ? 'документ' : d.name),
                ].join(', ')}',
                style: context.texts.bodySmall?.copyWith(color: context.et.inkFaint),
              ),
            ],
          ],
        ),
      );
    }
    if (isFinished(order)) {
      return _panel(state: _PanelState.locked, title: title, subtitle: 'Заказ закрыт — шаг уже не отметить.');
    }
    if (stage == 'cancelled' || !reached(order, 'animal_selected')) {
      return _panel(
        state: _PanelState.locked,
        title: title,
        subtitle: 'Откроется после первого шага.',
      );
    }
    return _panel(
      state: _PanelState.current,
      title: title,
      subtitle: 'Покажите готовое мясо, приложите документы и взвесьте тушу. Ветсправки животного '
          'платформа приложит сама.',
      action: _StepUploader(
        key: ValueKey('meat-${order.id}'),
        partnerId: order.partnerId,
        orderId: order.id,
        allowVideo: true,
        withDocuments: true,
        weighing: order.pricePerKg > 0 ? _WeighingContext(order: order) : null,
        buttonLabel: 'Готово — шаг 2 пройден',
        emptyHint: 'Нужно хотя бы одно фото или видео мяса.',
        busy: _busy,
        onSubmit: (files, extra) => _run(() => _api.meatReady(
              order.id,
              files: files,
              documents: extra.documents,
              scalePhoto: extra.scalePhoto,
              weightKg: extra.weightKg,
            )),
      ),
    );
  }

  Widget _shipPanel(FarmOrder order) {
    final stage = stageOf(order.status);
    final step = order.steps['shipped'];
    final title = order.delivery.isPickup ? 'Шаг 3. Готов к выдаче' : 'Шаг 3. Отправка';

    if (step != null) {
      return _panel(state: _PanelState.done, title: title, when: step.at);
    }
    if (isFinished(order)) {
      return _panel(state: _PanelState.locked, title: title, subtitle: 'Заказ закрыт — шаг уже не отметить.');
    }
    if (stage == 'cancelled' || !reached(order, 'meat_ready')) {
      return _panel(state: _PanelState.locked, title: title, subtitle: 'Откроется после второго шага.');
    }
    return _panel(
      state: _PanelState.current,
      title: title,
      subtitle: order.delivery.isPickup
          ? 'Отметьте, когда заказ готов к выдаче в хабе — покупатель увидит это у себя.'
          : 'Отметьте, когда заказ выехал к покупателю.',
      action: FilledButton(
        onPressed: _busy ? null : () => _run(() => _api.shipOrder(order.id)),
        child: Text(order.delivery.isPickup ? 'Готов к выдаче' : 'Заказ отправлен'),
      ),
    );
  }

  Widget _handoverPanel(FarmOrder order) {
    final stage = stageOf(order.status);
    final step = order.steps['handover'];
    const title = 'Шаг 4. Передача покупателю';

    if (stage == 'completed') {
      return _panel(
        state: _PanelState.done,
        title: 'Сделка завершена',
        when: order.completedAt,
        subtitle: completedBy[order.completedBy] ?? '',
      );
    }
    if (step != null) {
      return _panel(
        state: _PanelState.done,
        title: title,
        when: step.at,
        subtitle: order.autoCompleteAt == null
            ? 'Ждём подтверждения покупателя.'
            : 'Если покупатель не подтвердит, сделка закроется сама '
                '${_time(order.autoCompleteAt!)}.',
      );
    }
    if (isFinished(order)) {
      return _panel(state: _PanelState.locked, title: title, subtitle: 'Заказ закрыт — шаг уже не отметить.');
    }
    if (stage == 'cancelled' || !reached(order, 'shipped')) {
      return _panel(state: _PanelState.locked, title: title, subtitle: 'Откроется после отправки.');
    }
    return _panel(
      state: _PanelState.current,
      title: title,
      subtitle: 'Отметьте передачу, когда мясо у покупателя. После этого у него 3 часа на '
          'подтверждение — потом сделка закроется сама.',
      action: FilledButton(
        onPressed: _busy ? null : () => _run(() => _api.handoverOrder(order.id)),
        child: const Text('Передал покупателю'),
      ),
    );
  }

  // ---- money ---------------------------------------------------------------------------------

  Widget _money(FarmOrder order) {
    final payouts = order.payouts;
    final c = context.et;
    final weighing = order.weighing;

    return EtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.payments_outlined, size: 18, color: c.green),
              const SizedBox(width: 8),
              Text('Ваши деньги', style: context.texts.titleSmall),
            ],
          ),
          const SizedBox(height: 6),
          // Оплата покупателя — первой строкой. Пока заказ не оплачен, сервер не даст его
          // принять, и хозяйство должно видеть причину, а не упираться в отказ.
          if (!order.payment.isDirect) ...[
            EtRow(
              label: 'Оплата покупателя',
              sub: switch (order.payment.status) {
                'awaiting' => 'ждём оплаты — заказ пока нельзя принять',
                'authorized' => 'деньги заблокированы, спишутся при принятии заказа',
                'captured_partial' || 'captured_full' => 'деньги у платформы',
                'failed' => 'оплата не прошла, покупатель может повторить',
                'expired' => 'счёт истёк',
                'cancelled' => 'блокировка снята',
                'refund_pending' => 'оформляется возврат покупателю',
                'refunded' => 'деньги возвращены покупателю',
                _ => '',
              },
              value: order.payment.isSettled ? 'Оплачен' : 'Не оплачен',
              valueColor: order.payment.isSettled ? c.green : c.rust,
            ),
            const Divider(height: 18),
          ],
          EtRow(label: 'Сумма заказа', value: formatTenge(order.amount)),
          if (weighing != null)
            EtRow(
              label: 'После взвешивания',
              sub: weighing.difference > 0
                  ? 'доплата ${formatTenge(weighing.difference)}'
                  : weighing.difference < 0
                      ? 'возврат ${formatTenge(-weighing.difference)}'
                      : 'без перерасчёта',
              value: formatTenge(weighing.total),
              strong: true,
            ),
          if (payouts == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'План выплат появится, когда вы примете заказ.',
                style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
              ),
            )
          else ...[
            const Divider(height: 22),
            EtRow(
              label: 'Ваша доля',
              sub: 'за вычетом комиссии платформы 10 %',
              value: formatTenge(payouts.net),
              strong: true,
            ),
            for (final part in payoutParts)
              _payoutRow(part, switch (part.key) {
                'advance' => payouts.advance,
                'meat' => payouts.meat,
                _ => payouts.finalPart,
              }),
            const SizedBox(height: 10),
            // Про деньги покупателя сказано выше, строкой «Оплата покупателя», — и сказано
            // по факту заказа. Здесь остаётся то, что верно всегда: выплаты на счёт
            // хозяйства — следующий этап, а на экране пока план.
            EtNotice(
              text: order.payment.isDirect
                  ? 'Расчёт с покупателем идёт напрямую. Здесь видно, как считается ваша доля.'
                  : 'Деньги держит платформа. Выплата на ваш счёт — следующий этап, '
                        'пока это план по шагам.',
              icon: Icons.info_outline,
            ),
          ],
        ],
      ),
    );
  }

  Widget _payoutRow(PayoutPartLabel label, PayoutPart part) {
    final c = context.et;
    final color = switch (part.status) {
      'unlocked' => c.green,
      'blocked' || 'withheld' => c.danger,
      'cancelled' => c.inkFaint,
      _ => c.inkDim,
    };
    return EtRow(
      label: label.label,
      sub: '${payoutState[part.status] ?? part.status} · ${label.when}',
      value: formatTenge(part.amount),
      valueColor: color,
    );
  }

  // ---- panel chrome --------------------------------------------------------------------------

  Widget _panel({
    required _PanelState state,
    required String title,
    String? subtitle,
    DateTime? when,
    Widget? body,
    Widget? action,
  }) {
    final c = context.et;
    final locked = state == _PanelState.locked;
    return Opacity(
      opacity: locked ? 0.55 : 1,
      child: EtCard(
        tinted: state == _PanelState.current,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  switch (state) {
                    _PanelState.done => Icons.check_circle,
                    _PanelState.current => Icons.radio_button_checked,
                    _PanelState.locked => Icons.lock_outline,
                  },
                  size: 20,
                  color: state == _PanelState.done ? c.green : (locked ? c.inkFaint : c.green),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: context.texts.titleSmall)),
                if (when != null)
                  Text(_time(when), style: context.texts.bodySmall?.copyWith(color: c.inkFaint)),
              ],
            ),
            if (subtitle != null && subtitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 30),
                child: Text(
                  subtitle,
                  style: context.texts.bodySmall?.copyWith(color: c.inkDim, height: 1.4),
                ),
              ),
            if (body != null) Padding(padding: const EdgeInsets.only(top: 12), child: body),
            if (action != null) Padding(padding: const EdgeInsets.only(top: 14), child: action),
          ],
        ),
      ),
    );
  }

  List<EtMediaItem> _media(List<StepFile> files) =>
      files.map((f) => EtMediaItem(url: f.url, isVideo: f.isVideo, name: f.name)).toList();

  String _time(DateTime at) {
    final local = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}, ${two(local.hour)}:${two(local.minute)}';
  }
}

enum _PanelState { locked, current, done }

/// What step 2 needs besides its photos.
class _StepExtra {
  const _StepExtra({this.documents = const [], this.scalePhoto, this.weightKg});

  final List<StepFile> documents;
  final StepFile? scalePhoto;
  final double? weightKg;
}

class _WeighingContext {
  const _WeighingContext({required this.order});
  final FarmOrder order;
}

/// Taking a step: the camera first, the gallery second, an upload bar while it goes.
///
/// Files are uploaded as they are taken rather than all at once at the end - a video from a yard
/// on mobile data can take minutes, and a farmer should be able to shoot the next one meanwhile.
class _StepUploader extends StatefulWidget {
  const _StepUploader({
    super.key,
    required this.partnerId,
    required this.orderId,
    required this.buttonLabel,
    required this.emptyHint,
    required this.onSubmit,
    this.allowVideo = false,
    this.withDocuments = false,
    this.weighing,
    this.busy = false,
  });

  final String partnerId;
  final String orderId;
  final String buttonLabel;
  final String emptyHint;
  final bool allowVideo;
  final bool withDocuments;
  final _WeighingContext? weighing;
  final bool busy;
  final void Function(List<StepFile> files, _StepExtra extra) onSubmit;

  @override
  State<_StepUploader> createState() => _StepUploaderState();
}

class _StepUploaderState extends State<_StepUploader> {
  final _picker = ImagePicker();
  final _uploads = Uploads();
  final _weight = TextEditingController();

  final List<StepFile> _files = [];
  final List<StepFile> _documents = [];
  StepFile? _scalePhoto;

  double? _progress;
  String? _problem;

  @override
  void dispose() {
    _weight.dispose();
    super.dispose();
  }

  Future<void> _pick({
    required ImageSource source,
    bool video = false,
    String target = 'files',
  }) async {
    setState(() => _problem = null);
    try {
      final XFile? picked = video
          ? await _picker.pickVideo(
              source: source,
              maxDuration: const Duration(minutes: 3),
            )
          : await _picker.pickImage(source: source, imageQuality: 85, maxWidth: 1920);
      if (picked == null) return;

      setState(() => _progress = 0);
      final file = await _uploads.orderFile(
        partnerId: widget.partnerId,
        orderId: widget.orderId,
        file: File(picked.path),
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      if (!mounted) return;
      setState(() {
        _progress = null;
        switch (target) {
          case 'documents':
            _documents.add(file);
          case 'scale':
            _scalePhoto = file;
          default:
            _files.add(file);
        }
      });
    } on UploadRefused catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _problem = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _progress = null;
          _problem = 'Не удалось загрузить файл. Проверьте связь.';
        });
      }
    }
  }

  double? get _enteredWeight {
    final text = _weight.text.trim().replaceAll(',', '.');
    final value = double.tryParse(text);
    return value != null && value > 0 ? value : null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final uploading = _progress != null;
    final weighing = widget.weighing;
    final ready = _files.isNotEmpty && (weighing == null || _enteredWeight != null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _pickButton(Icons.photo_camera_outlined, 'Снять фото',
                () => _pick(source: ImageSource.camera)),
            if (widget.allowVideo)
              _pickButton(Icons.videocam_outlined, 'Снять видео',
                  () => _pick(source: ImageSource.camera, video: true)),
            _pickButton(Icons.photo_library_outlined, 'Из галереи',
                () => _pick(source: ImageSource.gallery)),
          ],
        ),
        if (uploading) ...[
          const SizedBox(height: 12),
          EtProgress(percent: _progress ?? 0, label: 'Загружаем файл', trailing: '${((_progress ?? 0) * 100).round()} %'),
        ],
        if (_files.isNotEmpty) ...[
          const SizedBox(height: 12),
          EtMediaStrip(
            items: _files
                .map((f) => EtMediaItem(url: f.url, isVideo: f.isVideo, name: f.name))
                .toList(),
            onRemove: (item) => setState(() => _files.removeWhere((f) => f.url == item.url)),
          ),
        ],

        if (widget.withDocuments) ...[
          const SizedBox(height: 18),
          Text('Документы на мясо', style: context.texts.titleSmall),
          Text(
            'Справка о прохождении ветконтроля, заключение — снимите или выберите фото. '
            'Ветдокументы животного платформа приложит сама.',
            style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _pickButton(Icons.document_scanner_outlined, 'Снять документ',
                  () => _pick(source: ImageSource.camera, target: 'documents')),
              _pickButton(Icons.attach_file, 'Из галереи',
                  () => _pick(source: ImageSource.gallery, target: 'documents')),
            ],
          ),
          if (_documents.isNotEmpty) ...[
            const SizedBox(height: 10),
            EtMediaStrip(
              size: 72,
              items: _documents
                  .map((f) => EtMediaItem(url: f.url, isVideo: false, name: f.name))
                  .toList(),
              onRemove: (item) => setState(() => _documents.removeWhere((f) => f.url == item.url)),
            ),
          ],
        ],

        if (weighing != null) ...[
          const SizedBox(height: 18),
          Text('Контрольное взвешивание', style: context.texts.titleSmall),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _weight,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Вес туши, кг', hintText: '66,2'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pick(source: ImageSource.camera, target: 'scale'),
                  icon: Icon(_scalePhoto == null ? Icons.photo_camera_outlined : Icons.check, size: 18),
                  label: Text(_scalePhoto == null ? 'Фото весов' : 'Весы сняты'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _weighingPreview(weighing.order),
        ],

        if (_problem != null) ...[
          const SizedBox(height: 12),
          EtNotice(text: _problem!, icon: Icons.error_outline, tone: 'danger'),
        ],

        const SizedBox(height: 14),
        FilledButton(
          onPressed: (!ready || uploading || widget.busy)
              ? null
              : () => widget.onSubmit(
                    _files,
                    _StepExtra(
                      documents: _documents,
                      scalePhoto: _scalePhoto,
                      weightKg: _enteredWeight,
                    ),
                  ),
          child: Text(widget.buttonLabel),
        ),
        if (!ready)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _files.isEmpty
                  ? widget.emptyHint
                  : 'Укажите вес по контрольному взвешиванию.',
              style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
            ),
          ),
      ],
    );
  }

  /// What the weighing does to the money, before the step is sent. The same arithmetic the server
  /// runs afterwards, so the farmer sees the surcharge or the refund at the scale - not later.
  Widget _weighingPreview(FarmOrder order) {
    final weight = _enteredWeight;
    final c = context.et;
    if (weight == null) {
      return Text(
        'Вес с весов, после разделки. Итог заказа пересчитается по нему: '
        '${formatTenge(order.pricePerKg)}/кг.',
        style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
      );
    }
    final meat = (order.pricePerKg * weight).round();
    final total = meat + order.pricing.cutting + order.pricing.delivery;
    final difference = total - order.amount;
    return EtCard(
      tinted: true,
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          EtRow(
            label: 'Мясо',
            sub: '${kgText(weight)} кг × ${formatTenge(order.pricePerKg)}',
            value: formatTenge(meat),
          ),
          EtRow(label: 'Итог заказа', value: formatTenge(total), strong: true),
          EtRow(
            label: difference > 0
                ? 'Доплата покупателя'
                : difference < 0
                    ? 'Возврат покупателю'
                    : 'Перерасчёта нет',
            value: difference == 0 ? '—' : formatTenge(difference.abs()),
            valueColor: difference > 0 ? c.green : (difference < 0 ? c.rust : null),
          ),
        ],
      ),
    );
  }

  Widget _pickButton(IconData icon, String label, VoidCallback onTap) => OutlinedButton.icon(
        onPressed: _progress != null ? null : onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
      );
}
