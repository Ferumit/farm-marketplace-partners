import 'package:cloud_firestore/cloud_firestore.dart';
import 'vet_document.dart';

/// Represents a group of animals assembled into a lot for sale.
class Lot {
  final String id;
  final String partnerId;
  final String name;
  final String description;
  final List<String> animalIds; // IDs of animals included in this lot
  final double totalWeight;
  final double pricePerShare;
  final String status; // 'draft', 'open', 'fully_booked', 'in_transit', 'sold'
  final int totalShares; // e.g. 4 (means 1/4 fractions)
  final int bookedShares;
  final String? imageUrl;
  final String location;
  final String? meatType; // 'cattle'/'horse' - copied from the lot's first animal at creation,
                           // so callers don't need to join through animalIds just to filter/label
  final List<VetDocument> vetDocuments;
  final DateTime createdAt;

  Lot({
    required this.id,
    required this.partnerId,
    required this.name,
    this.description = '',
    required this.animalIds,
    this.totalWeight = 0,
    this.pricePerShare = 0,
    this.status = 'draft',
    this.totalShares = 4,
    this.bookedShares = 0,
    this.imageUrl,
    this.location = 'Казахстан',
    this.meatType,
    this.vetDocuments = const [],
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  double get bookingPercent =>
      totalShares == 0 ? 0 : bookedShares / totalShares;

  bool get isFullyBooked => bookedShares >= totalShares;

  String get statusLabel {
    switch (status) {
      case 'draft': return 'ЧЕРНОВИК';
      case 'open': return 'ОТКРЫТ';
      case 'fully_booked': return 'ПОЛНОСТЬЮ ЗАБРОНИРОВАН';
      case 'in_transit': return 'В ПУТИ';
      case 'sold': return 'ПРОДАН';
      default: return status.toUpperCase();
    }
  }

  Map<String, dynamic> toMap() => {
    'partnerId': partnerId,
    'name': name,
    'description': description,
    'animalIds': animalIds,
    'totalWeight': totalWeight,
    'pricePerShare': pricePerShare,
    'status': status,
    'totalShares': totalShares,
    'bookedShares': bookedShares,
    'imageUrl': imageUrl,
    'location': location,
    'meatType': meatType,
    'vetDocuments': vetDocuments.map((doc) => doc.toMap()).toList(),
    'createdAt': Timestamp.fromDate(createdAt),
  };

  factory Lot.fromMap(String id, Map<String, dynamic> map) => Lot(
    id: id,
    partnerId: map['partnerId'] ?? '',
    name: map['name'] ?? map['title'] ?? '',
    description: map['description'] ?? '',
    animalIds: List<String>.from(map['animalIds'] ?? []),
    totalWeight: (map['totalWeight'] as num?)?.toDouble() ?? 0,
    pricePerShare: (map['pricePerShare'] as num?)?.toDouble() ?? 0,
    status: map['status'] ?? 'draft',
    totalShares: (map['totalShares'] as num?)?.toInt() ?? 4,
    bookedShares: (map['bookedShares'] as num?)?.toInt() ?? 0,
    imageUrl: map['imageUrl'] as String?,
    location: map['location'] ?? 'Казахстан',
    meatType: map['meatType'] as String?,
    vetDocuments: (map['vetDocuments'] as List<dynamic>?)
            ?.map((e) => VetDocument.fromMap(Map<String, dynamic>.from(e)))
            .toList() ??
        [],
    createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
  );
}
