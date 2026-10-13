// The road an order travels, as both apps read it. Mirrors updateOrderStatus on the server: what
// it refuses, these screens must not offer.
import 'package:et_core/et_core.dart';
import 'package:test/test.dart';

FarmOrder order(String status, {Map<String, dynamic> extra = const {}}) => FarmOrder.fromMap(
      'o1',
      {
        'buyerUid': 'buyer',
        'partnerId': 'farm',
        'lotId': 'lot',
        'lotTitle': 'Туша',
        'status': status,
        'amount': 232500,
        'format': 'half',
        'estimatedWeightKg': 65,
        ...extra,
      },
    );

void main() {
  group('statuses', () {
    test('old statuses read as their new equivalents', () {
      expect(stageOf('pending_payment'), 'created');
      expect(stageOf('confirmed'), 'accepted');
      expect(stageOf('in_progress'), 'animal_selected');
      expect(stageOf('meat_ready'), 'meat_ready');
    });

    test('each side is told the same state in its own words', () {
      final o = order('delivered');
      expect(statusTextForBuyer(o), 'Передан вам — подтвердите получение');
      expect(statusTextForFarm(o), 'Передан — ждём подтверждения');
      expect(statusTone(o), 'waiting');
      expect(statusTone(order('disputed')), 'danger');
    });

    test('the farm always knows its next step', () {
      expect(farmNextStep(order('created')), 'Примите заказ');
      expect(farmNextStep(order('animal_selected')), 'Шаг 2: мясо, документы и взвешивание');
      expect(farmNextStep(order('completed')), isNull);
    });
  });

  group('progress', () {
    test('a completed order has passed every step', () {
      final o = order('completed');
      for (final stage in orderRoad) {
        expect(reached(o, stage), isTrue, reason: stage);
      }
    });

    test('a cancelled order shows only that it was placed', () {
      final o = order('cancelled');
      expect(reached(o, 'created'), isTrue);
      expect(reached(o, 'accepted'), isFalse);
    });

    test('a dispute leaves the order where it was opened', () {
      final shipped = order('disputed', extra: {
        'steps': {
          'identify': {'at': DateTime.now()},
          'meat': {'at': DateTime.now()},
          'shipped': {'at': DateTime.now()},
        }
      });
      expect(reached(shipped, 'shipped'), isTrue);
      expect(reached(shipped, 'delivered'), isFalse);

      final handed = order('disputed', extra: {
        'steps': {
          'shipped': {'at': DateTime.now()},
          'handover': {'at': DateTime.now()},
        }
      });
      expect(reached(handed, 'delivered'), isTrue);
    });
  });

  group('what the buyer may do', () {
    test('cancelling is possible until the slaughter', () {
      expect(canCancel(order('created')), isTrue);
      expect(canCancel(order('animal_selected')), isTrue);
      expect(canCancel(order('meat_ready')), isFalse);
      expect(canCancel(order('completed')), isFalse);
    });

    test('confirming and disputing open at delivery', () {
      expect(canConfirm(order('meat_ready')), isFalse);
      expect(canConfirm(order('shipped')), isTrue);
      expect(canConfirm(order('delivered')), isTrue);
      expect(canConfirm(order('completed')), isFalse);
    });

    test('an order is finished once completed or cancelled', () {
      expect(isFinished(order('completed')), isTrue);
      expect(isFinished(order('cancelled')), isTrue);
      expect(isFinished(order('shipped')), isFalse);
    });
  });

  group('the three hours after handover', () {
    test('an order whose time is up may be closed by either side', () {
      final late = order('delivered', extra: {
        'autoCompleteAt': DateTime.now().subtract(const Duration(minutes: 1)),
      });
      expect(isOverdue(late), isTrue);
    });

    test('before the time is up, nobody closes it', () {
      final fresh = order('delivered', extra: {
        'autoCompleteAt': DateTime.now().add(const Duration(hours: 2)),
      });
      expect(isOverdue(fresh), isFalse);
      expect(isOverdue(order('shipped')), isFalse);
    });
  });

  group('money on the order', () {
    test('the weighing replaces the estimate as the order total', () {
      final weighed = order('meat_ready', extra: {
        'weighing': {'weightKg': 66.2, 'meat': 231700, 'total': 236700, 'difference': 4200},
        'payouts': {
          'net': 213030,
          'advance': {'amount': 104625, 'status': 'unlocked'},
          'meat': {'amount': 54203, 'status': 'unlocked'},
          'final': {'amount': 54202, 'status': 'locked'},
        },
      });
      expect(weighed.total, 236700);
      expect(weighed.weighing!.difference, 4200);
      expect(weighed.payouts!.advance.status, 'unlocked');
      expect(weighed.payouts!.finalPart.amount, 54202);
      // The three parts always add up to the farm's share, to the tenge.
      final parts = weighed.payouts!.advance.amount +
          weighed.payouts!.meat.amount +
          weighed.payouts!.finalPart.amount;
      expect(parts, weighed.payouts!.net);
    });

    test('an order without a weighing keeps its agreed amount', () {
      expect(order('accepted').total, 232500);
    });
  });

  group('a joint purchase behind an order', () {
    test('everyone in it is listed with their share', () {
      final joint = order('created', extra: {
        'group': {
          'id': 'g1',
          'size': 3,
          'members': [
            {'uid': 'a', 'name': 'Асхат', 'amount': 163334},
            {'uid': 'b', 'name': 'Болат', 'amount': 163333},
            {'uid': 'c', 'name': 'Сауле', 'amount': 163333},
          ],
        },
        'memberUids': ['a', 'b', 'c'],
      });
      expect(joint.isJoint, isTrue);
      expect(joint.group!.size, 3);
      expect(joint.group!.members.map((m) => m.amount).reduce((a, b) => a + b), 490000);
      expect(joint.memberUids.contains('c'), isTrue);
    });
  });
}
