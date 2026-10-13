import 'package:cloud_functions/cloud_functions.dart';
import 'package:et_core/et_core.dart';

/// Everything that moves money, stock or evidence goes through a callable function.
///
/// Not because it is convenient, but because it is the only place it can be checked: the rules
/// refuse a client that writes an order, a booked share or a payout, and they are right to. The
/// server answers in Russian when it refuses ("Свободной половины не осталось."), so those
/// messages are shown to the person as they are - they are better than anything an app could
/// invent from an error code.
class EtApi {
  EtApi({FirebaseFunctions? functions})
      : _functions = functions ??
            FirebaseFunctions.instanceFor(region: Paths.functionsRegion);

  final FirebaseFunctions _functions;

  Future<Map<String, dynamic>> _call(String name, Map<String, dynamic> data) async {
    try {
      final result = await _functions.httpsCallable(name).call<dynamic>(data);
      final value = result.data;
      return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
    } on FirebaseFunctionsException catch (e) {
      throw EtApiException(e.code, e.message);
    }
  }

  /// Places an order for a half or a whole carcass. Only the CHOICE is sent: the server prices
  /// it from the lot and the farm's storefront, so nothing a phone says can set a price.
  Future<String> createOrder({
    required String lotId,
    required String format,
    String? cuttingId,
    String? deliveryId,
    String deliveryAddress = '',
    String? deliveryDate,
    String? deliverySlot,
    required String contactPhone,
    required String idempotencyKey,
  }) async {
    final result = await _call(Paths.fnCreateOrder, {
      'lotId': lotId,
      'format': format,
      'cuttingId': cuttingId,
      'deliveryId': deliveryId,
      'deliveryAddress': deliveryAddress,
      'deliveryDate': deliveryDate,
      'deliverySlot': deliverySlot,
      'contactPhone': contactPhone,
      // One key per attempt: a retry after a lost answer returns the order already made instead
      // of booking the carcass twice.
      'idempotencyKey': idempotencyKey,
    });
    return asText(result['orderId']);
  }

  /// One step of an order's road. `payload` carries what that step needs - its files, the
  /// control weighing, the dispute's description.
  Future<String> updateOrderStatus(
    String orderId,
    String action, {
    Map<String, dynamic> payload = const {},
  }) async {
    final result = await _call(Paths.fnUpdateOrderStatus, {
      ...payload,
      'orderId': orderId,
      'action': action,
    });
    return asText(result['status']);
  }

  /// The farm accepts the order and its 50 % advance is fixed.
  Future<String> acceptOrder(String orderId) =>
      updateOrderStatus(orderId, OrderAction.accept);

  /// Step 1: the live animal, filmed or photographed.
  Future<String> identifyAnimal(String orderId, List<StepFile> files) => updateOrderStatus(
        orderId,
        OrderAction.identify,
        payload: {'files': files.map((f) => f.toMap()).toList()},
      );

  /// Step 2: the ready meat, its documents and the control weighing that fixes the real price.
  Future<String> meatReady(
    String orderId, {
    required List<StepFile> files,
    List<StepFile> documents = const [],
    StepFile? scalePhoto,
    double? weightKg,
  }) =>
      updateOrderStatus(orderId, OrderAction.meatReady, payload: {
        'files': files.map((f) => f.toMap()).toList(),
        'documents': documents.map((f) => f.toMap()).toList(),
        if (scalePhoto != null) 'scalePhoto': scalePhoto.toMap(),
        if (weightKg != null) 'weightKg': weightKg,
      });

  Future<String> shipOrder(String orderId) => updateOrderStatus(orderId, OrderAction.ship);

  Future<String> handoverOrder(String orderId) =>
      updateOrderStatus(orderId, OrderAction.handover);

  Future<String> completeOrder(String orderId) =>
      updateOrderStatus(orderId, OrderAction.complete);

  /// Closes a deal whose three hours after handover have passed. Either side may, and the
  /// scheduled sweep does the same every 15 minutes - this is what keeps an app that is open
  /// from showing a deal that should already be closed.
  Future<String> autoCompleteOrder(String orderId) =>
      updateOrderStatus(orderId, OrderAction.autocomplete);

  Future<String> disputeOrder(String orderId, {required String description, String? mediaUrl}) =>
      updateOrderStatus(orderId, OrderAction.dispute, payload: {
        'description': description,
        if (mediaUrl != null) 'mediaUrl': mediaUrl,
      });

  Future<String> cancelOrder(String orderId) => updateOrderStatus(orderId, OrderAction.cancel);

  /// Ссылка на страницу оплаты Freedom Pay для этого заказа.
  ///
  /// Сумму не передаём и передать не можем: сервер берёт её из заказа. Карту вводят на их
  /// странице — у приложения она не появляется ни на мгновение, поэтому ни PCI DSS, ни права на
  /// хранение карт нам не нужны.
  ///
  /// Открывать во внешнем браузере, а не в WebView: 3-D Secure и банковские приложения внутри
  /// WebView ломаются. Возврат ловится App Link'ом на /pay/return.
  Future<String> startPayment(String orderId) async {
    final res = await _call('startPayment', {'orderId': orderId});
    final url = res['redirectUrl'] as String?;
    if (url == null || url.isEmpty) {
      throw EtApiException('unavailable', 'Платёжный сервис не дал ссылку.');
    }
    return url;
  }

  /// The buyer of a completed deal rates the farm. It waits for a moderator before it is public.
  Future<void> submitReview({
    required String orderId,
    required int rating,
    String text = '',
  }) =>
      _call(Paths.fnSubmitReview, {'orderId': orderId, 'rating': rating, 'text': text});

  /// Gathers a joint purchase: 2-5 people splitting one carcass.
  Future<String> createGroupBuy({
    required String lotId,
    required String format,
    required int size,
    String? cuttingId,
    String? deliveryId,
    String deliveryAddress = '',
    String? deliveryDate,
    String? deliverySlot,
    required String contactPhone,
  }) async {
    final result = await _call(Paths.fnCreateGroupBuy, {
      'lotId': lotId,
      'format': format,
      'size': size,
      'cuttingId': cuttingId,
      'deliveryId': deliveryId,
      'deliveryAddress': deliveryAddress,
      'deliveryDate': deliveryDate,
      'deliverySlot': deliverySlot,
      'contactPhone': contactPhone,
    });
    return asText(result['groupId']);
  }

  /// Joins one - and, if this fills the last place, the order is placed for everyone and its id
  /// comes back.
  Future<GroupJoinResult> joinGroupBuy(String groupId) async {
    final result = await _call(Paths.fnJoinGroupBuy, {'groupId': groupId});
    return GroupJoinResult(
      status: asText(result['status']),
      orderId: asTextOrNull(result['orderId']),
      joined: asInt(result['joined']),
      size: asInt(result['size']),
    );
  }

  Future<String> leaveGroupBuy(String groupId) async {
    final result = await _call(Paths.fnLeaveGroupBuy, {'groupId': groupId});
    return asText(result['status']);
  }

  /// Sets the farm's hub point. The exact point stays private; buyers see it snapped to a ~5 km
  /// grid, which the server derives in the same transaction.
  /// Удаление аккаунта. Отказ - это не ошибка связи: сервер называет причину словами, которые
  /// можно показать человеку («есть незакрытый заказ», «идёт сбор»), и EtApiException несёт
  /// именно их.
  Future<void> deleteMyAccount({required String role}) =>
      _call(Paths.fnDeleteMyAccount, {'role': role});

  Future<void> setHubLocation({double? lat, double? lng, bool clear = false}) => _call(
        Paths.fnSetHubLocation,
        clear ? {'clear': true} : {'lat': lat, 'lng': lng},
      );
}

class GroupJoinResult {
  const GroupJoinResult({
    required this.status,
    this.orderId,
    this.joined = 0,
    this.size = 0,
  });

  /// open | placed | failed
  final String status;
  final String? orderId;
  final int joined;
  final int size;
}

/// A refusal from the server, with the sentence it wrote for the person.
class EtApiException implements Exception {
  EtApiException(this.code, String? message)
      : message = (message == null || message.isEmpty || code == 'internal')
            // An internal failure has no sentence worth showing, and the person did nothing wrong.
            ? 'Что-то пошло не так на сервере. Попробуйте чуть позже.'
            : message;

  final String code;
  final String message;

  @override
  String toString() => message;
}
