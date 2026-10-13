import '../values.dart';

/// One of the farm's paid cutting options, priced per HALF carcass (a whole costs twice).
class CuttingOption {
  const CuttingOption({required this.id, required this.name, required this.price, this.note});

  final String id;
  final String name;
  final int price;
  final String? note;

  factory CuttingOption.fromMap(Map<String, dynamic> map) => CuttingOption(
        id: asText(map['id']),
        name: asText(map['name']),
        price: asInt(map['price']),
        note: asTextOrNull(map['note']),
      );

  Map<String, dynamic> toMap() => {'id': id, 'name': name, 'price': price, if (note != null) 'note': note};
}

/// The farm's own delivery tariff for one city.
class DeliveryTariff {
  const DeliveryTariff({required this.id, required this.city, required this.price});

  final String id;
  final String city;
  final int price;

  factory DeliveryTariff.fromMap(Map<String, dynamic> map) => DeliveryTariff(
        id: asText(map['id']),
        city: asText(map['city']),
        price: asInt(map['price']),
      );

  Map<String, dynamic> toMap() => {'id': id, 'city': city, 'price': price};
}

/// The hub point buyers see - snapped to a ~5 km grid by setHubLocation, never the exact yard.
class HubPoint {
  const HubPoint({required this.lat, required this.lng, this.precisionKm = 5});

  final double lat;
  final double lng;
  final int precisionKm;

  static HubPoint? fromMap(dynamic value) {
    final map = asMap(value);
    if (map.isEmpty || map['lat'] == null || map['lng'] == null) return null;
    return HubPoint(
      lat: asDouble(map['lat']),
      lng: asDouble(map['lng']),
      precisionKm: asInt(map['precisionKm']) == 0 ? 5 : asInt(map['precisionKm']),
    );
  }
}

/// What the farm set up in its cabinet: who it is, its slaughterhouse on video, and the terms a
/// buyer needs before choosing a carcass.
class Storefront {
  const Storefront({
    this.description = '',
    this.videoUrl,
    this.posterUrl,
    this.pickup = false,
    this.cutting = const [],
    this.delivery = const [],
  });

  final String description;
  final String? videoUrl;
  final String? posterUrl;
  final bool pickup;
  final List<CuttingOption> cutting;
  final List<DeliveryTariff> delivery;

  factory Storefront.fromMap(Map<String, dynamic> map) => Storefront(
        description: asText(map['description']),
        videoUrl: asTextOrNull(map['videoUrl']),
        posterUrl: asTextOrNull(map['posterUrl']),
        pickup: asBool(map['pickup']),
        cutting: asMapList(map['cutting']).map(CuttingOption.fromMap).toList(),
        delivery: asMapList(map['delivery']).map(DeliveryTariff.fromMap).toList(),
      );

  Map<String, dynamic> toMap() => {
        'description': description,
        'videoUrl': videoUrl,
        'posterUrl': posterUrl,
        'pickup': pickup,
        'cutting': cutting.map((c) => c.toMap()).toList(),
        'delivery': delivery.map((d) => d.toMap()).toList(),
      };

  bool get isEmpty =>
      description.isEmpty && videoUrl == null && cutting.isEmpty && delivery.isEmpty && !pickup;
}

/// A farm as buyers see it. Everything the PLATFORM decides about a farm - its status, rating,
/// deals, balances, the certified badge and the public point - is written by the server only; the
/// apps read those and never send them back (firestore.rules refuses if they try).
class Partner {
  const Partner({
    required this.id,
    required this.displayName,
    this.phone = '',
    this.status = 'pending_review',
    this.city,
    this.regionCode,
    this.avatarUrl,
    this.certified = false,
    this.rating = 0,
    this.reviewsCount = 0,
    this.totalDeals = 0,
    this.walletBalance = 0,
    this.pendingBalance = 0,
    this.storefront = const Storefront(),
    this.publicLocation,
    this.createdAt,
  });

  final String id;
  final String displayName;
  final String phone;

  /// pending_review | verified | active | rejected
  final String status;
  final String? city;
  final String? regionCode;
  final String? avatarUrl;
  final bool certified;
  final double rating;
  final int reviewsCount;
  final int totalDeals;

  /// The farm's own money, in whole tenge. Written by the server as orders move - the apps show
  /// it and never send it back, and firestore.rules refuses if they try.
  final int walletBalance;
  final int pendingBalance;

  final Storefront storefront;
  final HubPoint? publicLocation;
  final DateTime? createdAt;

  /// Only a farm the platform has checked sells - the same rule the server enforces in
  /// createOrder, so the apps must not show anyone else's lots.
  bool get sells => status == 'verified' || status == 'active';

  factory Partner.fromMap(String id, Map<String, dynamic> map) => Partner(
        id: id,
        displayName: asText(map['displayName']),
        phone: asText(map['phone']),
        status: asText(map['status']).isEmpty ? 'pending_review' : asText(map['status']),
        city: asTextOrNull(map['city']),
        regionCode: asTextOrNull(map['regionCode']),
        avatarUrl: asTextOrNull(map['avatarUrl']),
        certified: asBool(map['certified']),
        rating: asDouble(map['rating']),
        reviewsCount: asInt(map['reviewsCount']),
        totalDeals: asInt(map['totalDeals']),
        walletBalance: asInt(map['walletBalance']),
        pendingBalance: asInt(map['pendingBalance']),
        storefront: Storefront.fromMap(asMap(map['storefront'])),
        publicLocation: HubPoint.fromMap(map['publicLocation']),
        createdAt: asTime(map['createdAt']),
      );
}
