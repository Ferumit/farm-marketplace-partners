import '../values.dart';

/// A lot is ONE CARCASS.
///
/// `totalShares` 2 means it sells in halves (a half is one share, the whole carcass both);
/// 1 means whole only. Quarters would be 4 with the same arithmetic - which is why a format is
/// counted in shares rather than kept as a list. Meat is priced per kilogram of carcass on
/// `totalWeight`; lots made before that carry `pricePerShare` instead and are still sold.
class Lot {
  const Lot({
    required this.id,
    required this.partnerId,
    required this.name,
    this.description = '',
    this.animalIds = const [],
    this.status = 'draft',
    this.totalShares = 0,
    this.bookedShares = 0,
    this.pricePerKg = 0,
    this.totalWeight = 0,
    this.pricePerShare = 0,
    this.imageUrl,
    this.meatType,
    this.regionCode,
    this.location,
    this.createdAt,
  });

  final String id;
  final String partnerId;
  final String name;
  final String description;
  final List<String> animalIds;

  /// draft | open | fully_booked | in_transit | sold
  final String status;
  final int totalShares;
  final int bookedShares;

  /// ₸ per kilogram of carcass; 0 on lots from before the carcass model.
  final int pricePerKg;

  /// Kilograms of the WHOLE carcass, approximate until the control weighing.
  final double totalWeight;

  /// The older way of pricing: ₸ per share.
  final int pricePerShare;

  final String? imageUrl;

  /// cattle | horse - written at creation, or derived from the first animal.
  final String? meatType;
  final String? regionCode;
  final String? location;
  final DateTime? createdAt;

  int get freeShares => (totalShares - bookedShares).clamp(0, totalShares);
  bool get isOpen => status == 'open';

  factory Lot.fromMap(String id, Map<String, dynamic> map) => Lot(
        id: id,
        partnerId: asText(map['partnerId']),
        name: asText(map['name']),
        description: asText(map['description']),
        animalIds: asTextList(map['animalIds']),
        status: asText(map['status']).isEmpty ? 'draft' : asText(map['status']),
        totalShares: asInt(map['totalShares']),
        bookedShares: asInt(map['bookedShares']),
        pricePerKg: asInt(map['pricePerKg']),
        totalWeight: asDouble(map['totalWeight']),
        pricePerShare: asInt(map['pricePerShare']),
        imageUrl: asTextOrNull(map['imageUrl']),
        meatType: asTextOrNull(map['meatType']),
        regionCode: asTextOrNull(map['regionCode']),
        location: asTextOrNull(map['location']),
        createdAt: asTime(map['createdAt']),
      );

  /// What a farm may write. `bookedShares` is here only for creation, where the rules demand a
  /// zero; it never moves from a client afterwards - createOrder and updateOrderStatus own it.
  Map<String, dynamic> toCreateMap() => {
        'partnerId': partnerId,
        'name': name,
        'description': description,
        'animalIds': animalIds,
        'status': status,
        'totalShares': totalShares,
        'bookedShares': 0,
        'pricePerKg': pricePerKg,
        'totalWeight': totalWeight,
        'pricePerShare': pricePerShare,
        'imageUrl': imageUrl,
        'meatType': meatType,
        'regionCode': regionCode,
        'location': location,
      };
}
