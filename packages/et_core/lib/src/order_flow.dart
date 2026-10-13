/// The road an order travels, in the words each side needs.
///
///   created ─accept─▶ accepted ─identify─▶ animal_selected ─meat_ready─▶ meat_ready
///   meat_ready ─ship─▶ shipped ─handover─▶ delivered ─complete or 3 h later─▶ completed
///   shipped | delivered ─dispute─▶ disputed ─staff decide─▶ completed
///   created | accepted | animal_selected ─cancel─▶ cancelled
///
/// Mirrors updateOrderStatus (functions/index.js) and js/order-status.js. Orders placed before
/// this flow carry the old statuses and are read as their new equivalents, here as there.
library;

import 'models/order.dart';

const legacyStage = {
  'pending_payment': 'created',
  'confirmed': 'accepted',
  'in_progress': 'animal_selected',
};

String stageOf(String status) => legacyStage[status] ?? status;

/// The actions updateOrderStatus accepts. The server checks who may send which - these names
/// only have to match it exactly.
class OrderAction {
  static const accept = 'accept';
  static const identify = 'identify';
  static const meatReady = 'meat_ready';
  static const ship = 'ship';
  static const handover = 'handover';
  static const complete = 'complete';
  static const autocomplete = 'autocomplete';
  static const dispute = 'dispute';
  static const cancel = 'cancel';
}

class _Status {
  const _Status(this.buyer, this.farm, this.tone);
  final String buyer;
  final String farm;
  final String tone;
}

/// tone: neutral | active | waiting | danger | off - the app maps it to its own colours.
const _statuses = {
  'created': _Status('Ждёт подтверждения хозяйства', 'Новый — примите заказ', 'waiting'),
  'accepted': _Status('Принят хозяйством', 'Принят — снимите животное', 'active'),
  'animal_selected': _Status('Животное выбрано', 'Животное показано — готовьте мясо', 'active'),
  'meat_ready': _Status('Мясо готово', 'Мясо готово — отправьте заказ', 'active'),
  'shipped': _Status('Заказ в пути', 'Отправлен — отметьте передачу', 'active'),
  'delivered': _Status('Передан вам — подтвердите получение', 'Передан — ждём подтверждения', 'waiting'),
  'completed': _Status('Сделка завершена', 'Сделка завершена', 'neutral'),
  'disputed': _Status('Спор на рассмотрении', 'Покупатель открыл спор', 'danger'),
  'cancelled': _Status('Отменён', 'Отменён', 'off'),
};

String statusTextForBuyer(FarmOrder order) =>
    _statuses[stageOf(order.status)]?.buyer ?? order.status;

String statusTextForFarm(FarmOrder order) =>
    _statuses[stageOf(order.status)]?.farm ?? order.status;

String statusTone(FarmOrder order) => _statuses[stageOf(order.status)]?.tone ?? 'off';

const orderRoad = [
  'created',
  'accepted',
  'animal_selected',
  'meat_ready',
  'shipped',
  'delivered',
  'completed',
];

/// Whether the order has got as far as `stage`. A dispute stops it where it was opened.
bool reached(FarmOrder order, String stage) {
  final at = stageOf(order.status);
  if (at == 'cancelled') return stage == 'created';
  final effective = at == 'disputed'
      ? (order.steps.containsKey('handover') ? 'delivered' : 'shipped')
      : at;
  return orderRoad.indexOf(effective) >= orderRoad.indexOf(stage);
}

bool isFinished(FarmOrder order) =>
    stageOf(order.status) == 'completed' || stageOf(order.status) == 'cancelled';

/// Cancelling is possible until the farm has slaughtered - leadership's answer 15.
bool canCancel(FarmOrder order) =>
    ['created', 'accepted', 'animal_selected'].contains(stageOf(order.status));

bool canConfirm(FarmOrder order) => ['shipped', 'delivered'].contains(stageOf(order.status));

/// A deal whose buyer let the 3 hours pass. Either side's screen may close it when it sees one -
/// the scheduled sweep does the same every 15 minutes.
bool isOverdue(FarmOrder order) {
  final at = order.autoCompleteAt;
  return stageOf(order.status) == 'delivered' && at != null && !at.isAfter(DateTime.now());
}

/// What the farm has to do next, in one line - the order desk shows it on every card.
String? farmNextStep(FarmOrder order) {
  switch (stageOf(order.status)) {
    case 'created':
      return 'Примите заказ';
    case 'accepted':
      return 'Шаг 1: снимите животное';
    case 'animal_selected':
      return 'Шаг 2: мясо, документы и взвешивание';
    case 'meat_ready':
      return 'Шаг 3: отправьте заказ';
    case 'shipped':
      return 'Шаг 4: отметьте передачу';
    case 'delivered':
      return 'Ждём подтверждения покупателя';
    default:
      return null;
  }
}

/// The three parts of the farm's share (payoutPlan in functions/index.js).
class PayoutPartLabel {
  const PayoutPartLabel(this.key, this.label, this.when);
  final String key;
  final String label;
  final String when;
}

const payoutParts = [
  PayoutPartLabel('advance', 'Аванс 50 %', 'при принятии заказа'),
  PayoutPartLabel('meat', '25 %', 'когда мясо готово'),
  PayoutPartLabel('final', '25 %', 'после завершения сделки'),
];

const payoutState = {
  'locked': 'ждёт своего шага',
  'unlocked': 'открыт',
  'blocked': 'заблокирован спором',
  'withheld': 'удержан по решению спора',
  'cancelled': 'заказ отменён',
};

const completedBy = {
  'buyer': 'покупатель подтвердил получение',
  'auto': 'автоматически через 3 часа после передачи',
  'dispute': 'по решению платформы',
};

const disputeOutcomeForBuyer = {
  'buyer': 'В вашу пользу',
  'partner': 'В пользу хозяйства',
  'partial': 'Частично в вашу пользу',
  'withdrawn': 'Претензия отозвана',
};

/// The four steps as both sides see them, in order.
class StepView {
  const StepView(this.key, this.stage, this.buyerTitle, this.farmTitle);
  final String key;
  final String stage;
  final String buyerTitle;
  final String farmTitle;
}

const orderSteps = [
  StepView('identify', 'animal_selected', 'Животное выбрано', 'Шаг 1. Живое животное'),
  StepView('meat', 'meat_ready', 'Мясо готово', 'Шаг 2. Готовое мясо и взвешивание'),
  StepView('shipped', 'shipped', 'Заказ в пути', 'Шаг 3. Отправка'),
  StepView('handover', 'delivered', 'Передан вам', 'Шаг 4. Передача покупателю'),
];
