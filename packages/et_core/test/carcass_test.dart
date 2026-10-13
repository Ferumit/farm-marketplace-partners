// The same arithmetic the server does in priceOrder (functions/index.js). The numbers below are
// taken from the end-to-end runs on the emulator, so if one of these breaks, an app is about to
// show a price the server will refuse to charge.
import 'package:et_core/et_core.dart';
import 'package:test/test.dart';

Lot carcass({
  int totalShares = 2,
  int bookedShares = 0,
  int pricePerKg = 3500,
  double totalWeight = 130,
  int pricePerShare = 0,
  String status = 'open',
}) =>
    Lot(
      id: 'lot',
      partnerId: 'farm',
      name: 'Казахская белоголовая, торпақ',
      status: status,
      totalShares: totalShares,
      bookedShares: bookedShares,
      pricePerKg: pricePerKg,
      totalWeight: totalWeight,
      pricePerShare: pricePerShare,
    );

const storefront = Storefront(
  pickup: true,
  cutting: [CuttingOption(id: 'c1', name: 'Традиционная Мүшелеу', price: 15000)],
  delivery: [
    DeliveryTariff(id: 'd1', city: 'Астана', price: 5000),
    DeliveryTariff(id: 'd2', city: 'Караганда', price: 15000),
  ],
);

void main() {
  group('formats', () {
    test('a carcass of two halves: 3 500 ₸/кг × 130 кг', () {
      final formats = formatsOf(carcass());
      expect(formats['half']!.meat, 227500);
      expect(formats['half']!.weight, 65);
      expect(formats['whole']!.meat, 455000);
      expect(formats['whole']!.weight, 130);
      expect(formats['half']!.available, isTrue);
      expect(formats['whole']!.available, isTrue);
    });

    test('one half booked: the other is still free, the whole carcass is not', () {
      final formats = formatsOf(carcass(bookedShares: 1));
      expect(formats['half']!.available, isTrue);
      expect(formats['whole']!.available, isFalse);
      expect(bestOffer(carcass(bookedShares: 1))!.format, 'half');
    });

    test('a carcass sold whole only has no half', () {
      final formats = formatsOf(carcass(totalShares: 1));
      expect(formats['half']!.sellable, isFalse);
      expect(formats['whole']!.meat, 455000);
    });

    test('a lot from before the carcass model keeps its price per share', () {
      final formats = formatsOf(carcass(pricePerKg: 0, totalWeight: 0, pricePerShare: 77000));
      expect(formats['half']!.meat, 77000);
      expect(formats['whole']!.meat, 154000);
      expect(formats['half']!.weight, isNull);
    });

    test('a lot that is not on sale offers nothing', () {
      expect(formatsOf(carcass(status: 'draft'))['half']!.available, isFalse);
      expect(bestOffer(carcass(status: 'fully_booked')), isNull);
    });
  });

  group('quote', () {
    test('whole carcass, cutting on both halves, delivery to Астана = 490 000 ₸', () {
      final q = quote(carcass(), storefront, format: 'whole', cuttingId: 'c1', deliveryId: 'd1');
      expect(q.meat, 455000);
      expect(q.cutting, 30000); // priced per half, so a whole costs twice
      expect(q.delivery, 5000);
      expect(q.total, 490000);
    });

    test('half carcass, standard cutting, pickup = only the meat', () {
      final q = quote(carcass(), storefront, format: 'half', deliveryId: 'pickup');
      expect(q.cutting, 0);
      expect(q.delivery, 0);
      expect(q.total, 227500);
    });

    test('a cutting the farm has removed is simply not charged', () {
      final q = quote(carcass(), storefront, format: 'half', cuttingId: 'gone');
      expect(q.cutting, 0);
      expect(q.total, 227500);
    });

    test('delivery options put pickup first', () {
      final options = deliveryOptions(storefront);
      expect(options.first.id, 'pickup');
      expect(options.map((o) => o.label), ['Самовывоз из хаба', 'Астана', 'Караганда']);
    });
  });

  group('words', () {
    test('availability', () {
      expect(availabilityLabel(carcass()), 'Свободны обе половины');
      expect(availabilityLabel(carcass(bookedShares: 1)), 'Свободна одна половина');
      expect(availabilityLabel(carcass(bookedShares: 2, status: 'fully_booked')), 'Туша забронирована');
      expect(availabilityLabel(carcass(status: 'draft')), 'Не опубликована');
      expect(availabilityLabel(carcass(totalShares: 1)), 'Продаётся целиком');
    });

    test('money and plurals', () {
      expect(formatTenge(232500), '232 500 ₸');
      expect(formatTenge(0), '0 ₸');
      expect(formatTenge(1000000), '1 000 000 ₸');
      expect(pluralRu(1, 'туша', 'туши', 'туш'), 'туша');
      expect(pluralRu(2, 'туша', 'туши', 'туш'), 'туши');
      expect(pluralRu(5, 'туша', 'туши', 'туш'), 'туш');
      expect(pluralRu(11, 'туша', 'туши', 'туш'), 'туш');
    });

    test('weights use a decimal comma', () {
      expect(kgText(66.25), '66,3');
      expect(kgText(65), '65');
      expect(weightLabel(62.4), '~62,4 кг');
      expect(weightLabel(null), '');
    });

    test('what an order is for', () {
      expect(orderSummary(format: 'half', estimatedWeightKg: 65), 'Половина туши · ~65 кг');
      expect(orderSummary(shares: 3), '3 доли');
    });
  });
}
