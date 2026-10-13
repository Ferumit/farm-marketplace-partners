/// Formats, weights and prices of one carcass.
///
/// This is the same arithmetic as `priceOrder` in functions/index.js and `js/carcass.js` on the
/// website. The server stays the only authority - it prices every order again from the lot and
/// the farm's storefront - but a buyer must never be shown one number and charged another, so
/// the three copies are kept deliberately identical and tested here.
library;

import 'models/lot.dart';
import 'models/partner.dart';
import 'money.dart';

const formatLabel = {'half': 'Половина туши', 'whole': 'Целая туша'};
const formatKz = {'half': 'жарты', 'whole': 'тұтас'};
const slotLabel = {
  'any': 'Любое время',
  'morning': 'Утро, 9:00–12:00',
  'day': 'День, 12:00–16:00',
  'evening': 'Вечер, 16:00–20:00',
};
const meatLabel = {'cattle': 'Говядина', 'horse': 'Конина'};

/// How many of the lot's shares a format takes, or 0 when the lot cannot be sold that way.
int sharesFor(Lot lot, String format) {
  final total = lot.totalShares;
  if (format == 'whole') return total;
  if (format == 'half') return total >= 2 && total % 2 == 0 ? total ~/ 2 : 0;
  return 0;
}

/// One way of buying a carcass: whether it is sold that way at all, whether it is still free,
/// and roughly what it weighs and what the meat costs.
class FormatOffer {
  const FormatOffer({
    required this.format,
    required this.shares,
    required this.sellable,
    required this.available,
    required this.weight,
    required this.meat,
  });

  final String format;
  final int shares;
  final bool sellable;
  final bool available;
  final double? weight;
  final int meat;

  String get label => formatLabel[format] ?? '';
}

Map<String, FormatOffer> formatsOf(Lot lot) {
  final out = <String, FormatOffer>{};
  for (final format in ['half', 'whole']) {
    final shares = sharesFor(lot, format);
    final available = lot.isOpen &&
        shares > 0 &&
        (format == 'whole'
            ? lot.bookedShares == 0
            : lot.totalShares - lot.bookedShares >= shares);
    final meat = _meatOf(lot, shares);
    out[format] = FormatOffer(
      format: format,
      shares: shares,
      sellable: shares > 0,
      available: available,
      weight: meat.weight,
      meat: meat.amount,
    );
  }
  return out;
}

class _MeatPrice {
  const _MeatPrice(this.weight, this.amount);
  final double? weight;
  final int amount;
}

_MeatPrice _meatOf(Lot lot, int shares) {
  final total = lot.totalShares;
  if (shares == 0 || total == 0) return const _MeatPrice(null, 0);
  final fraction = shares / total;
  final weight = lot.totalWeight > 0 ? (lot.totalWeight * fraction * 10).round() / 10 : null;
  if (lot.pricePerKg > 0 && lot.totalWeight > 0) {
    return _MeatPrice(weight, (lot.pricePerKg * lot.totalWeight * fraction).round());
  }
  // Lots from before the carcass model: priced per share.
  return _MeatPrice(weight, lot.pricePerShare * shares);
}

/// The cheapest way in that is still free: a half if there is one.
FormatOffer? bestOffer(Lot lot) {
  final formats = formatsOf(lot);
  if (formats['half']!.available) return formats['half'];
  if (formats['whole']!.available) return formats['whole'];
  return null;
}

/// Everything the farm offers for delivery: pickup first, then its cities. Empty means the two
/// sides agree it between themselves after the order.
class DeliveryChoice {
  const DeliveryChoice({required this.id, required this.label, required this.price});
  final String id;
  final String label;
  final int price;
}

List<DeliveryChoice> deliveryOptions(Storefront storefront) => [
      if (storefront.pickup)
        const DeliveryChoice(id: 'pickup', label: 'Самовывоз из хаба', price: 0),
      ...storefront.delivery
          .map((d) => DeliveryChoice(id: d.id, label: d.city, price: d.price)),
    ];

/// The amounts for one choice - a preview of what createOrder will charge.
class Quote {
  const Quote({
    required this.weight,
    required this.meat,
    required this.cutting,
    required this.delivery,
    required this.total,
    this.cuttingOption,
    this.deliveryTariff,
  });

  final double? weight;
  final int meat;
  final int cutting;
  final int delivery;
  final int total;
  final CuttingOption? cuttingOption;
  final DeliveryTariff? deliveryTariff;
}

Quote quote(
  Lot lot,
  Storefront storefront, {
  required String format,
  String? cuttingId,
  String? deliveryId,
}) {
  final offer = formatsOf(lot)[format];
  final halves = format == 'whole' ? 2 : 1;
  CuttingOption? cut;
  for (final option in storefront.cutting) {
    if (cuttingId != null && option.id == cuttingId) cut = option;
  }
  DeliveryTariff? tariff;
  if (deliveryId != null && deliveryId != 'pickup') {
    for (final option in storefront.delivery) {
      if (option.id == deliveryId) tariff = option;
    }
  }
  final meat = offer?.meat ?? 0;
  final cutting = cut == null ? 0 : cut.price * halves;
  final delivery = tariff?.price ?? 0;
  return Quote(
    weight: offer?.weight,
    meat: meat,
    cutting: cutting,
    delivery: delivery,
    total: meat + cutting + delivery,
    cuttingOption: cut,
    deliveryTariff: tariff,
  );
}

/// "Свободны обе половины" - what is left of a carcass, in words.
String availabilityLabel(Lot lot) {
  final total = lot.totalShares;
  final free = lot.freeShares;
  if (lot.status == 'draft') return 'Не опубликована';
  if (lot.status != 'open' && lot.status != 'fully_booked') return 'Снята с продажи';
  if (lot.status == 'fully_booked' || free == 0) return 'Туша забронирована';
  if (total == 1) return 'Продаётся целиком';
  if (total == 2) return free == 2 ? 'Свободны обе половины' : 'Свободна одна половина';
  if (free == total) return 'Свободна вся туша';
  return free >= total / 2 ? 'Свободна половина' : 'Свободно меньше половины';
}

/// What an order is for: "Половина туши · ~60 кг", or the share count of an older one.
String orderSummary({String? format, double? estimatedWeightKg, int shares = 0}) {
  if (format != null && formatLabel.containsKey(format)) {
    final weight = weightLabel(estimatedWeightKg);
    return weight.isEmpty ? formatLabel[format]! : '${formatLabel[format]} · $weight';
  }
  return '$shares ${pluralRu(shares, 'доля', 'доли', 'долей')}';
}
