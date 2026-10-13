import 'package:cloud_firestore/cloud_firestore.dart';
import 'vet_document.dart';

class Animal {
  final String id;
  final String partnerId;
  final String breed;
  final String subBreed;
  final String status; // 'active', 'pending_inspection', 'sold'
  final double weight;
  final String ageCategory; // 'тай', 'кунан', 'бесті'
  final String gender; // 'male', 'female'
  final String type; // 'cattle', 'horse', etc.
  final String? imageUrl;
  final String? notes;
  final List<VetDocument> vetDocuments;
  final double price; // per kg, ₸ - also read by ET_side_client's Animal model
  final String region; // also read by ET_side_client's Animal model
  final DateTime createdAt;

  Animal({
    required this.id,
    required this.partnerId,
    required this.breed,
    required this.subBreed,
    this.status = 'active',
    required this.weight,
    required this.ageCategory,
    required this.gender,
    required this.type,
    this.imageUrl,
    this.notes,
    this.vetDocuments = const [],
    this.price = 0.0,
    this.region = 'Unknown',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Generates a display ID like #BR-8821
  String get displayId {
    final prefix = breed.length >= 2 ? breed.substring(0, 2).toUpperCase() : 'AN';
    final suffix = id.hashCode.abs() % 10000;
    return '#$prefix-$suffix';
  }

  /// Localized status label
  String get statusLabel {
    switch (status) {
      case 'active':
        return 'АКТИВЕН';
      case 'pending_inspection':
        return 'ОЖИДАЕТ ОСМОТРА';
      case 'sold':
        return 'ПРОДАН';
      default:
        return status.toUpperCase();
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'partnerId': partnerId,
      'breed': breed,
      'subBreed': subBreed,
      'status': status,
      'weight': weight,
      'ageCategory': ageCategory,
      'gender': gender,
      'type': type,
      'imageUrl': imageUrl,
      'notes': notes,
      'vetDocuments': vetDocuments.map((doc) => doc.toMap()).toList(),
      'price': price,
      'region': region,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  factory Animal.fromMap(String id, Map<String, dynamic> map) {
    return Animal(
      id: id,
      partnerId: map['partnerId'] ?? '',
      breed: map['breed'] ?? '',
      subBreed: map['subBreed'] ?? '',
      status: map['status'] ?? 'active',
      weight: (map['weight'] as num?)?.toDouble() ?? 0.0,
      ageCategory: map['ageCategory'] ?? '',
      gender: map['gender'] ?? 'male',
      type: map['type'] ?? 'cattle',
      imageUrl: map['imageUrl'],
      notes: map['notes'],
      vetDocuments: (map['vetDocuments'] as List<dynamic>?)
              ?.map((e) => VetDocument.fromMap(Map<String, dynamic>.from(e)))
              .toList() ??
          [],
      price: (map['price'] as num?)?.toDouble() ?? 0.0,
      region: map['region'] ?? 'Unknown',
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}
