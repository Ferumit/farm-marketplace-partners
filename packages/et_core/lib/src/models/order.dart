import '../values.dart';

/// A file one of the farm's steps carries: a photo, a video or a document.
class StepFile {
  const StepFile({required this.url, required this.kind, this.name = ''});

  final String url;

  /// photo | video | doc
  final String kind;
  final String name;

  bool get isVideo => kind == 'video';

  factory StepFile.fromMap(Map<String, dynamic> map) => StepFile(
        url: asText(map['url']),
        kind: asText(map['kind']),
        name: asText(map['name']),
      );

  Map<String, dynamic> toMap() => {'url': url, 'kind': kind, 'name': name};
}

/// A veterinary document of the animal, copied onto the order when the meat is ready.
class StepCertificate {
  const StepCertificate({required this.label, required this.url, this.status = 'pending'});

  final String label;
  final String url;
  final String status;

  factory StepCertificate.fromMap(Map<String, dynamic> map) => StepCertificate(
        label: asText(map['label']),
        url: asText(map['url']),
        status: asText(map['status']),
      );
}

/// One step of the farm's work, with whatever it filmed or attached.
class OrderStep {
  const OrderStep({
    this.at,
    this.files = const [],
    this.documents = const [],
    this.certificates = const [],
  });

  final DateTime? at;
  final List<StepFile> files;
  final List<StepFile> documents;
  final List<StepCertificate> certificates;

  bool get done => at != null;

  static OrderStep? fromMap(dynamic value) {
    final map = asMap(value);
    if (map.isEmpty) return null;
    return OrderStep(
      at: asTime(map['at']),
      files: asMapList(map['files']).map(StepFile.fromMap).toList(),
      documents: asMapList(map['documents']).map(StepFile.fromMap).toList(),
      certificates: asMapList(map['certificates']).map(StepCertificate.fromMap).toList(),
    );
  }
}

/// The control weighing after slaughter: what the carcass really weighed, what the order really
/// costs, and the difference the two sides settle - a surcharge or a refund.
class Weighing {
  const Weighing({
    required this.weightKg,
    this.meat,
    required this.total,
    required this.difference,
    this.scalePhoto,
    this.at,
  });

  final double weightKg;
  final int? meat;
  final int total;
  final int difference;
  final StepFile? scalePhoto;
  final DateTime? at;

  static Weighing? fromMap(dynamic value) {
    final map = asMap(value);
    if (map.isEmpty || map['weightKg'] == null) return null;
    final photo = asMap(map['scalePhoto']);
    return Weighing(
      weightKg: asDouble(map['weightKg']),
      meat: map['meat'] == null ? null : asInt(map['meat']),
      total: asInt(map['total']),
      difference: asInt(map['difference']),
      scalePhoto: photo.isEmpty ? null : StepFile.fromMap(photo),
      at: asTime(map['at']),
    );
  }
}

/// One of the three parts of the farm's share.
///
/// locked - its step has not happened yet; unlocked - it happened (and with payments on, it is
/// paid out); blocked - held by an open dispute; withheld - the dispute went against the farm;
/// cancelled - the order was cancelled.
class PayoutPart {
  const PayoutPart({required this.amount, required this.status, this.at});

  final int amount;
  final String status;
  final DateTime? at;

  factory PayoutPart.fromMap(dynamic value) {
    final map = asMap(value);
    return PayoutPart(
      amount: asInt(map['amount']),
      status: asText(map['status']).isEmpty ? 'locked' : asText(map['status']),
      at: asTime(map['at']),
    );
  }
}

/// The farm's share of an order - the total less the platform's commission - in three parts:
/// 50 % when the farm accepts, 25 % when the meat is ready, 25 % when the deal completes.
class Payouts {
  const Payouts({required this.net, required this.advance, required this.meat, required this.finalPart});

  final int net;
  final PayoutPart advance;
  final PayoutPart meat;
  final PayoutPart finalPart;

  static Payouts? fromMap(dynamic value) {
    final map = asMap(value);
    if (map.isEmpty) return null;
    return Payouts(
      net: asInt(map['net']),
      advance: PayoutPart.fromMap(map['advance']),
      meat: PayoutPart.fromMap(map['meat']),
      finalPart: PayoutPart.fromMap(map['final']),
    );
  }
}

/// Платёжная ось заказа — отдельная от оси работы хозяйства.
///
/// Две оси, потому что они действительно независимы: деньги можно вернуть по доставленному
/// заказу, а полностью оплаченный заказ может стоять непринятым. Единственная точка связи —
/// хозяйство не начинает работу по неоплаченному заказу.
///
/// `not_required` — заказ пилота: деньги через платформу по нему не идут вовсе. Это решение
/// записано на заказ в момент создания, поэтому экран читает его с заказа, а не угадывает по
/// настройкам приложения.
/// Фискальный чек по заказу — тот, что выбила касса ХОЗЯЙСТВА и принял ОФД.
///
/// Покупателю от этого нужна одна вещь: ссылка, по которой чек можно открыть и проверить в
/// налоговой. Номер и прочее — для нас и для разбирательств.
class OrderFiscal {
  const OrderFiscal({
    this.ticketNumber,
    this.url,
    this.amount,
    this.at,
    this.error,
    this.test = false,
  });

  final String? ticketNumber;

  /// Ссылка на чек у оператора фискальных данных. Печатать нам нечего, и это честнее бумаги:
  /// по ней покупатель видит тот же документ, что ушёл в налоговую.
  final String? url;
  final int? amount;
  final DateTime? at;

  /// Чек не выбился. Остаётся на заказе нарочно: молчаливое отсутствие чека хуже видимой
  /// ошибки — её хотя бы можно заметить и починить.
  final String? error;

  /// Чек с тестового контура re:Kassa: по виду настоящий, но в налоговую не ушёл. Пока боевого
  /// ключа нет, выбиваются именно такие, и покупателю надо сказать об этом прямо — выдать
  /// пробный документ за фискальный хуже, чем не показать никакого.
  ///
  /// По умолчанию `false`, и это безопасно: признак ставит сервер, а старые заказы, выбитые до
  /// его появления, тестовыми не были.
  final bool test;

  bool get issued => (url ?? '').isNotEmpty || (ticketNumber ?? '').isNotEmpty;

  static OrderFiscal? fromMap(dynamic value) {
    final map = asMap(value);
    if (map.isEmpty) return null;
    return OrderFiscal(
      ticketNumber: asTextOrNull(map['ticketNumber']),
      url: asTextOrNull(map['url']),
      amount: map['amount'] == null ? null : asInt(map['amount']),
      at: asTime(map['at']),
      error: asTextOrNull(map['error']),
      test: map['test'] == true,
    );
  }
}

class OrderPayment {
  const OrderPayment({
    this.status = 'not_required',
    this.provider,
    this.providerPaymentId,
    this.method,
    this.authorizedAmount = 0,
    this.capturedAmount = 0,
    this.refundedAmount = 0,
    this.failureCode,
  });

  /// not_required | awaiting | authorized | captured_partial | captured_full |
  /// failed | expired | refund_pending | refunded
  final String status;
  final String? provider;
  final String? providerPaymentId;
  final String? method;
  final int authorizedAmount;
  final int capturedAmount;
  final int refundedAmount;
  final String? failureCode;

  /// Деньги по заказу через платформу не идут — расчёт напрямую с хозяйством.
  bool get isDirect => status == 'not_required';

  /// Заказ оплачен: сумма либо заблокирована на карте, либо уже списана.
  bool get isSettled =>
      status == 'authorized' || status == 'captured_partial' || status == 'captured_full';

  /// Оплату можно начать или повторить.
  bool get canPay => status == 'awaiting' || status == 'failed' || status == 'expired';

  static OrderPayment fromMap(dynamic value) {
    final map = asMap(value);
    if (map.isEmpty) return const OrderPayment();
    return OrderPayment(
      status: asTextOrNull(map['status']) ?? 'not_required',
      provider: asTextOrNull(map['provider']),
      providerPaymentId: asTextOrNull(map['providerPaymentId']),
      method: asTextOrNull(map['method']),
      authorizedAmount: asInt(map['authorizedAmount']),
      capturedAmount: asInt(map['capturedAmount']),
      refundedAmount: asInt(map['refundedAmount']),
      failureCode: asTextOrNull(map['failureCode']),
    );
  }
}

/// A joint purchase behind one order: who shares it and what each of them pays.
class OrderGroup {
  const OrderGroup({required this.id, required this.size, this.members = const []});

  final String id;
  final int size;
  final List<GroupMember> members;

  static OrderGroup? fromMap(dynamic value) {
    final map = asMap(value);
    if (map.isEmpty) return null;
    return OrderGroup(
      id: asText(map['id']),
      size: asInt(map['size']),
      members: asMapList(map['members']).map(GroupMember.fromMap).toList(),
    );
  }
}

class GroupMember {
  const GroupMember({required this.uid, required this.name, required this.amount, this.joinedAt});

  final String uid;
  final String name;
  final int amount;
  final DateTime? joinedAt;

  factory GroupMember.fromMap(Map<String, dynamic> map) => GroupMember(
        uid: asText(map['uid']),
        name: asText(map['name']),
        amount: asInt(map['amount']),
        joinedAt: asTime(map['joinedAt']),
      );
}

/// How the order's amount was made up.
class OrderPricing {
  const OrderPricing({this.meat = 0, this.cutting = 0, this.delivery = 0, this.total = 0});

  final int meat;
  final int cutting;
  final int delivery;
  final int total;

  factory OrderPricing.fromMap(dynamic value) {
    final map = asMap(value);
    return OrderPricing(
      meat: asInt(map['meat']),
      cutting: asInt(map['cutting']),
      delivery: asInt(map['delivery']),
      total: asInt(map['total']),
    );
  }
}

/// The delivery chosen: the farm's tariff for a city, pickup from the hub, or by agreement.
class OrderDelivery {
  const OrderDelivery({this.mode = 'agree', this.id, this.city, this.amount = 0});

  final String mode;
  final String? id;
  final String? city;
  final int amount;

  bool get isPickup => mode == 'pickup';

  factory OrderDelivery.fromMap(dynamic value) {
    final map = asMap(value);
    return OrderDelivery(
      mode: asText(map['mode']).isEmpty ? 'agree' : asText(map['mode']),
      id: asTextOrNull(map['id']),
      city: asTextOrNull(map['city']),
      amount: asInt(map['amount']),
    );
  }
}

class OrderCutting {
  const OrderCutting({required this.id, required this.name, this.amount = 0});

  final String id;
  final String name;
  final int amount;

  static OrderCutting? fromMap(dynamic value) {
    final map = asMap(value);
    if (map.isEmpty) return null;
    return OrderCutting(id: asText(map['id']), name: asText(map['name']), amount: asInt(map['amount']));
  }
}

/// An order: one carcass (or half of one) from one farm, and everything that happened to it.
///
/// Nothing here is ever written from a client. Placing an order is createOrder and every move
/// along the road is updateOrderStatus, because each of them also touches the lot's shares, the
/// money or the evidence - see functions/index.js.
class FarmOrder {
  const FarmOrder({
    required this.id,
    required this.buyerUid,
    required this.partnerId,
    required this.lotId,
    this.lotTitle = '',
    this.buyerPhone,
    this.contactPhone = '',
    this.shares = 0,
    this.amount = 0,
    this.currency = 'KZT',
    this.format,
    this.estimatedWeightKg,
    this.pricePerKg = 0,
    this.pricing = const OrderPricing(),
    this.cutting,
    this.delivery = const OrderDelivery(),
    this.deliveryAddress = '',
    this.deliveryDate,
    this.deliverySlot,
    this.status = 'created',
    this.steps = const {},
    this.weighing,
    this.payouts,
    this.payment = const OrderPayment(),
    this.fiscal,
    this.fiscalReturn,
    this.group,
    this.memberUids = const [],
    this.disputeId,
    this.disputeOutcome,
    this.reviewId,
    this.completedBy,
    this.cancelledBy,
    this.acceptedAt,
    this.autoCompleteAt,
    this.completedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String buyerUid;
  final String partnerId;
  final String lotId;
  final String lotTitle;
  final String? buyerPhone;
  final String contactPhone;

  final int shares;
  final int amount;
  final String currency;

  /// half | whole - absent on orders from before the carcass model.
  final String? format;
  final double? estimatedWeightKg;
  final int pricePerKg;
  final OrderPricing pricing;
  final OrderCutting? cutting;
  final OrderDelivery delivery;
  final String deliveryAddress;

  /// "2026-10-01"
  final String? deliveryDate;

  /// morning | day | evening | any
  final String? deliverySlot;

  final String status;

  /// identify | meat | shipped | handover
  final Map<String, OrderStep> steps;
  final Weighing? weighing;
  final Payouts? payouts;

  /// Платёжная ось: идут ли по заказу деньги через платформу и на каком они шаге.
  final OrderPayment payment;

  /// Фискальные чеки: продажа и, если тушу взвесили легче, возврат разницы.
  final OrderFiscal? fiscal;
  final OrderFiscal? fiscalReturn;
  final OrderGroup? group;
  final List<String> memberUids;

  final String? disputeId;
  final String? disputeOutcome;
  final String? reviewId;

  /// buyer | auto | dispute
  final String? completedBy;

  /// buyer | partner
  final String? cancelledBy;

  final DateTime? acceptedAt;
  final DateTime? autoCompleteAt;
  final DateTime? completedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// What the order really costs once the carcass has been weighed.
  int get total => weighing?.total ?? amount;

  bool get isJoint => group != null;

  factory FarmOrder.fromMap(String id, Map<String, dynamic> map) {
    final rawSteps = asMap(map['steps']);
    final steps = <String, OrderStep>{};
    for (final key in ['identify', 'meat', 'shipped', 'handover']) {
      final step = OrderStep.fromMap(rawSteps[key]);
      if (step != null) steps[key] = step;
    }
    return FarmOrder(
      id: id,
      buyerUid: asText(map['buyerUid']),
      partnerId: asText(map['partnerId']),
      lotId: asText(map['lotId']),
      lotTitle: asText(map['lotTitle']),
      buyerPhone: asTextOrNull(map['buyerPhone']),
      contactPhone: asText(map['contactPhone']),
      shares: asInt(map['shares']),
      amount: asInt(map['amount']),
      currency: asText(map['currency']).isEmpty ? 'KZT' : asText(map['currency']),
      format: asTextOrNull(map['format']),
      estimatedWeightKg: map['estimatedWeightKg'] == null ? null : asDouble(map['estimatedWeightKg']),
      pricePerKg: asInt(map['pricePerKg']),
      pricing: OrderPricing.fromMap(map['pricing']),
      cutting: OrderCutting.fromMap(map['cutting']),
      delivery: OrderDelivery.fromMap(map['delivery']),
      deliveryAddress: asText(map['deliveryAddress']),
      deliveryDate: asTextOrNull(map['deliveryDate']),
      deliverySlot: asTextOrNull(map['deliverySlot']),
      status: asText(map['status']).isEmpty ? 'created' : asText(map['status']),
      steps: steps,
      weighing: Weighing.fromMap(map['weighing']),
      payouts: Payouts.fromMap(map['payouts']),
      payment: OrderPayment.fromMap(map['payment']),
      fiscal: OrderFiscal.fromMap(map['fiscal']),
      fiscalReturn: OrderFiscal.fromMap(map['fiscalReturn']),
      group: OrderGroup.fromMap(map['group']),
      memberUids: asTextList(map['memberUids']),
      disputeId: asTextOrNull(map['disputeId']),
      disputeOutcome: asTextOrNull(map['disputeOutcome']),
      reviewId: asTextOrNull(map['reviewId']),
      completedBy: asTextOrNull(map['completedBy']),
      cancelledBy: asTextOrNull(map['cancelledBy']),
      acceptedAt: asTime(map['acceptedAt']),
      autoCompleteAt: asTime(map['autoCompleteAt']),
      completedAt: asTime(map['completedAt']),
      createdAt: asTime(map['createdAt']),
      updatedAt: asTime(map['updatedAt']),
    );
  }
}
